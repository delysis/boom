// SPDX-License-Identifier: MIT

import Foundation
import BoomCore
@testable import Boom
import MLX
import MLXLMCommon
import Testing

import MLXVLM

/// Real CPU forwards with tiny local weights. No model download or Metal work.
@Suite(.serialized)
struct Gemma4IndependentBatchTests {
    private static func model(perLayerInput: Int = 0, kEqualsV: Bool = true) throws -> Gemma4Unified {
        let json = """
            {
              "model_type": "gemma4_unified", "vocab_size": 32,
              "image_token_id": 31, "audio_token_id": 30, "video_token_id": 29,
              "text_config": {
                "hidden_size": 16, "num_hidden_layers": 4, "intermediate_size": 32,
                "num_attention_heads": 2, "num_key_value_heads": 1,
                "num_global_key_value_heads": 1, "head_dim": 8, "global_head_dim": 8,
                "vocab_size": 32, "vocab_size_per_layer_input": 32,
                "num_kv_shared_layers": 2, "hidden_size_per_layer_input": \(perLayerInput),
                "sliding_window": 512, "max_position_embeddings": 4096,
                "attention_k_eq_v": \(kEqualsV), "use_double_wide_mlp": false,
                "layer_types": ["sliding_attention", "full_attention", "sliding_attention", "full_attention"],
                "tie_word_embeddings": true
              },
              "vision_config": null, "audio_config": null
            }
            """
        let config = try JSONDecoder().decode(Gemma4UnifiedConfiguration.self, from: Data(json.utf8))
        let model = withRandomState(MLXRandom.RandomState(seed: 1984)) { Gemma4Unified(config) }
        eval(model)
        return model
    }

    private static func tokens(_ count: Int, row: Int) -> [Int32] {
        (0 ..< count).map { Int32(1 + ($0 * 7 + row * 11) % 28) }
    }

    private static func input(_ rows: [[Int32]]) -> LMInput {
        let width = rows.map(\.count).max()!
        let values = rows.flatMap { $0 + Array(repeating: Int32(0), count: width - $0.count) }
        let mask = rows.flatMap { Array(repeating: Int32(1), count: $0.count) + Array(repeating: Int32(0), count: width - $0.count) }
        return LMInput(text: .init(tokens: MLXArray(values).reshaped([rows.count, width]), mask: MLXArray(mask).reshaped([rows.count, width])))
    }

    private static func prepare(_ model: Gemma4Unified, rows: [[Int32]], cache: [any KVCache], step: Int) throws -> MLXArray {
        let result = try model.prepare(input(rows), cache: cache, state: nil, prefill: .init(stepSize: step))
        guard case .logits(let output) = result else { throw TestFailure.notLogits }
        let logits = output.logits[0..., -1, 0...]
        eval(logits, cache)
        return logits
    }

    private static func merge(_ rows: [[any KVCache]]) throws -> [any KVCache] {
        try (0 ..< rows[0].count).map { layer in
            try mergeBatchKVCache(rows.map { $0[layer] })
        }
    }

    private static func expectMatch(_ actual: MLXArray, _ expected: MLXArray) {
        let error = abs(actual - expected).max().item(Float.self)
        #expect(error < 5e-4, "Independent Gemma4 forward drift: \(error)")
        #expect(all(isFinite(actual)).item(Bool.self))
    }

    private enum TestFailure: Error { case notLogits }

    @Test("Extracted K/V owns a compact raw allocation rather than a contiguous cohort alias")
    func rowExtractionAllocatesAndPreservesRawBits() throws {
        try Device.withDefaultDevice(.cpu) {
            let bits: [UInt32] = [0x80000000, 0x7fc01234, 0x00000000, 0x3f800000]
            let values = (0 ..< 24_576).map { Float(bitPattern: bits[$0 % bits.count]) }
            let parent = MLXArray(values).reshaped([3, 2, 512, 8])
            let batch = BatchKVCache(leftPadding: [0, 0, 0])
            batch.state = [parent, parent, MLXArray([Int32(512), 512, 512]), MLXArray([Int32(0), 0, 0])]
            let view = parent[1 ..< 2, 0..., 0..., 0...]
            let row = try batch.extract(row: 1)
            let copied = row.state[0]
            eval(parent, view, copied)
            // This API is explicitly no-copy; all backing arrays remain live.
            let parentBytes = parent.asData(access: .noCopy)
            let viewBytes = view.asData(access: .noCopy)
            let rowBytes = copied.asData(access: .noCopy)
            parentBytes.data.withUnsafeBytes { parentMemory in
                viewBytes.data.withUnsafeBytes { viewMemory in
                    rowBytes.data.withUnsafeBytes { rowMemory in
                        let lower = UInt(bitPattern: parentMemory.baseAddress!)
                        let upper = lower + UInt(parent.nbytes)
                        let alias = UInt(bitPattern: viewMemory.baseAddress!)
                        let actual = UInt(bitPattern: rowMemory.baseAddress!)
                        #expect(alias >= lower && alias < upper) // actual negative control
                        #expect(actual < lower || actual >= upper)
                    }
                }
            }
            #expect(rowBytes.strides == [8_192, 4_096, 8, 1])
            #expect(rowBytes.data == view.asData(access: .copy).data)
            let allocation = try #require(copied.readyBuffer())
            let parentAllocation = try #require(parent.readyBuffer())
            #expect(allocation.byteOffset == 0 && allocation.allocationBytes >= copied.nbytes)
            #expect(allocation.allocationBytes < parentAllocation.allocationBytes)
            let aliasedAllocation = try #require(view.readyBuffer())
            #expect(aliasedAllocation.allocationBytes == parentAllocation.allocationBytes && aliasedAllocation.allocationBytes > allocation.allocationBytes)
            // The cache's public independent copy follows the same raw-copy rule.
            let clone = batch.copy().state[0]
            eval(clone)
            #expect(clone.asData(access: .copy).data == parent.asData(access: .copy).data)
        }
    }

    @Test("Uneven 511/512/513 prompts retain independent rows through prepare and shared KV tails")
    func unevenColdPrompts() throws {
        try Device.withDefaultDevice(.cpu) {
            let model = try Self.model()
            let prompts = [511, 512, 513].enumerated().map { Self.tokens($0.element, row: $0.offset) }
            let individual = try prompts.map { _ in try model.newCache(parameters: nil) }
            let batch = try Self.merge(individual)
            let actual = try Self.prepare(model, rows: prompts, cache: batch, step: 256)
            #expect(actual.shape == [3, 32])
            for row in prompts.indices {
                let expected = try Self.prepare(model, rows: [prompts[row]], cache: individual[row], step: 256)
                Self.expectMatch(actual[row ..< row + 1, 0...], expected)
                for layer in batch {
                    let cache = try #require(layer as? any BatchKVCacheProtocol)
                    let restored = try cache.extract(row: row)
                    #expect(restored.offset == prompts[row].count)
                }
            }
            // Distinct prompts must not become repetitions of a concatenated row.
            #expect(abs(actual[0, 0...] - actual[1, 0...]).max().item(Float.self) > 1e-5)
        }
    }

    @Test("Uneven warm prefixes and right-padded suffixes survive rotating 511/512/513 boundaries")
    func unevenWarmPrefixesThenDecode() throws {
        try Device.withDefaultDevice(.cpu) {
            let model = try Self.model()
            let lengths = [511, 512, 513]
            let individual = try lengths.map { _ in try model.newCache(parameters: nil) }
            for row in lengths.indices {
                _ = try Self.prepare(model, rows: [Self.tokens(lengths[row], row: row)], cache: individual[row], step: 256)
            }
            let batch = try Self.merge(individual.map { $0.map { $0.copy() } })
            let suffixes: [[Int32]] = [[7], [4, 11, 19, 23], [3, 17]]
            let actual = try Self.prepare(model, rows: suffixes, cache: batch, step: 2)
            for row in lengths.indices {
                let expected = try Self.prepare(model, rows: [suffixes[row]], cache: individual[row], step: 2)
                Self.expectMatch(actual[row ..< row + 1, 0...], expected)
            }
            // Exercise in-place ring decode after right padding has finalized.
            for turn in 0 ..< 4 {
                let next = lengths.indices.map { Int32(2 + $0 * 3 + turn) }
                let output = model(MLXArray(next).reshaped([3, 1]), cache: batch)
                eval(output, batch)
                for row in lengths.indices {
                    let expected = model(MLXArray([next[row]]).reshaped([1, 1]), cache: individual[row])
                    eval(expected, individual[row])
                    Self.expectMatch(output[row ..< row + 1, 0..., 0...], expected)
                }
            }
            // Extraction resumes the same row, including its absolute RoPE offset.
            for row in lengths.indices {
                let extracted = try batch.map { try ($0 as! any BatchKVCacheProtocol).extract(row: row) }
                #expect(extracted.allSatisfy { $0.offset == lengths[row] + suffixes[row].count + 4 })
                let token = MLXArray([Int32(14 + row)]).reshaped([1, 1])
                let actual = model(token, cache: extracted)
                let expected = model(token, cache: individual[row])
                eval(actual, expected)
                Self.expectMatch(actual, expected)
            }
        }
    }

    @Test("Short rows keep valid sliding context while longer rows consume several padded chunks")
    func paddingDoesNotEvictShortRows() throws {
        try Device.withDefaultDevice(.cpu) {
            let model = try Self.model()
            let prompts = [Self.tokens(1, row: 0), Self.tokens(513, row: 1), Self.tokens(1027, row: 2)]
            let individual = try prompts.map { _ in try model.newCache(parameters: nil) }
            let batch = try Self.merge(individual)
            let actual = try Self.prepare(model, rows: prompts, cache: batch, step: 128)
            for row in prompts.indices {
                let expected = try Self.prepare(model, rows: [prompts[row]], cache: individual[row], step: 128)
                Self.expectMatch(actual[row ..< row + 1, 0...], expected)
                let extracted = try batch.map { try ($0 as! any BatchKVCacheProtocol).extract(row: row) }
                #expect(extracted.allSatisfy { $0.offset == prompts[row].count })
                let token = MLXArray([Int32(9 + row)]).reshaped([1, 1])
                let continued = model(token, cache: extracted)
                let oracle = model(token, cache: individual[row])
                eval(continued, oracle)
                Self.expectMatch(continued, oracle)
            }
        }
    }

    @Test("Malformed batch masks and scalar caches refuse before changing actual cache positions")
    func invalidInputIsNotConcatenated() throws {
        try Device.withDefaultDevice(.cpu) {
            let model = try Self.model()
            let scalar = try model.newCache(parameters: nil)
            #expect(throws: (any Error).self) {
                _ = try model.prepare(Self.input([[1, 2], [3]]), cache: scalar, state: nil, prefill: .init())
            }
            #expect(scalar.allSatisfy { $0.offset == 0 })
            let batch = try Self.merge([scalar, try model.newCache(parameters: nil)])
            let input = LMInput(text: .init(tokens: MLXArray([1, 2, 3, 4, 5, 6]).reshaped([2, 3]), mask: MLXArray([1, 0, 1, 1, 1, 1]).reshaped([2, 3])))
            #expect(throws: (any Error).self) {
                _ = try model.prepare(input, cache: batch, state: nil, prefill: .init())
            }
            for layer in batch {
                #expect((layer as! any BatchKVCacheProtocol).batchOffset.asArray(Int.self) == [0, 0])
            }
            let emptyRow = Self.input([[], [1, 2]])
            #expect(throws: (any Error).self) {
                _ = try model.prepare(emptyRow, cache: batch, state: nil, prefill: .init())
            }
            #expect(batch.allSatisfy { $0.offset == 0 })
        }
    }

    @Test("Per-layer inputs, distinct K/V and shared tails preserve cold/warm ragged 512-boundary forwards")
    func perLayerInputsAndDistinctKVStayIndependent() throws {
        try Device.withDefaultDevice(.cpu) {
            let model = try Self.model(perLayerInput: 4, kEqualsV: false)
            let prefixes = [511, 512, 513].enumerated().map { Self.tokens($0.element, row: $0.offset) }
            let scalar = try prefixes.map { _ in try model.newCache(parameters: nil) }
            let cold = try Self.merge(prefixes.map { _ in try model.newCache(parameters: nil) })
            let logits = try Self.prepare(model, rows: prefixes, cache: cold, step: 512)
            for row in prefixes.indices {
                Self.expectMatch(logits[row], try Self.prepare(model, rows: [prefixes[row]], cache: scalar[row], step: 512)[0])
            }
            let merged = try Self.merge(scalar)
            let suffixes: [[Int32]] = [[5], [11, 12, 13, 14], [21, 22]]
            let warm = try Self.prepare(model, rows: suffixes, cache: merged, step: 512)
            for row in prefixes.indices {
                Self.expectMatch(warm[row], try Self.prepare(model, rows: [suffixes[row]], cache: scalar[row], step: 512)[0])
                let extracted = try merged.map { try ($0 as! any BatchKVCacheProtocol).extract(row: row) }
                let next = model(LMInput.Text(tokens: MLXArray([Int32(7)]).reshaped([1, 1])), cache: extracted, state: nil).logits
                let expected = model(LMInput.Text(tokens: MLXArray([Int32(7)]).reshaped([1, 1])), cache: scalar[row], state: nil).logits
                eval(next, expected); Self.expectMatch(next, expected)
            }
        }
    }

    private struct IDTokenizer: MLXLMCommon.Tokenizer {
        var bosToken: String? { nil }; var eosToken: String? { "31" }; var unknownToken: String? { nil }
        func encode(text: String, addSpecialTokens: Bool) -> [Int] { text.split(separator: " ").compactMap { Int($0) } }
        func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { tokenIds.map(String.init).joined(separator: " ") }
        func convertTokenToId(_ token: String) -> Int? { Int(token) }
        func convertIdToToken(_ id: Int) -> String? { String(id) }
        func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
            additionalContext: [String: any Sendable]?) throws -> [Int] { throw TestFailure.notLogits }
    }
    private actor Journals {
        var values: [UUID: GenerationCheckpoint] = [:]
        func accept(_ progress: GenerationProgress, identity: GenerationIdentity,
            stop: String?, token: Int?) throws {
            let next = GenerationCheckpoint(schema: 1, identity: identity, progress: progress,
                stopReason: stop, stopTokenID: token)
            values[identity.attemptID] = try ProductCore.generationCheckpoint(next, expected: identity,
                previous: values[identity.attemptID])
        }
        func value(_ id: UUID) -> GenerationCheckpoint? { values[id] }
    }
    private enum RowFailure: Error { case checkpoint }

    @Test("Real independent forwards isolate cancelled and failed-checkpoint rows and preserve peer seeds/journals")
    func independentDecodeKeepsPeerAfterRowCancellationAndCheckpointFailure() async throws {
        try await Device.withDefaultDevice(.cpu) {
            let model = try Self.model(perLayerInput: 4, kEqualsV: false)
            let prompts = [511, 512, 513].enumerated().map { Self.tokens($0.element, row: $0.offset).map(Int.init) }
            let policy = ModelGenerationPolicy(schema: 1, vocabularySize: 32, eosTokenIDs: [31],
                suppressedTokenIDs: [], controlTokenIDs: [31], textDecoding: "checkpoint_raw_v1",
                prefill: .init(chunking: "fixed_v1", tokenCeiling: 512))
            let seeds: [UInt64] = [7, 41, 151], journals = Journals()
            func run(faults: Bool) async throws -> (MLXGemmaRunner.IndependentTextDecoded,
                [MLXGemmaRunner.IndependentTextRequest], [GenerationExecutionOrigin]) {
                let parent = ProcessInfo.processInfo.environment["TMPDIR"].flatMap {
                    $0.hasPrefix("/") ? URL(fileURLWithPath: $0, isDirectory: true) : nil
                }
                let manager = PromptPrefixCache(temporaryParent: parent)
                let flags = prompts.map { _ in CancellationFlag() }
                let requests = prompts.indices.map { row in
                    let identity = GenerationIdentity(kind: .consultation, operationID: flags[row].operationID,
                        recordID: UUID(), attemptID: UUID(), model: "tiny-local-gemma4", seed: seeds[row],
                        requestDigest: Digest.sha256("independent-question-\(row)"), maxTokens: 4, generationPolicy: policy)
                    let owner = PromptCacheOwner(namespace: UUID(), entity: identity.recordID, route: .consultation)
                    return MLXGemmaRunner.IndependentTextRequest(identity: identity, owner: owner,
                        input: .raw("independent-question-\(row)"),
                        settings: .init(temperature: 0.7, topP: 1, topK: 4, minP: 0), flag: flags[row], policy: policy,
                        onPrefill: { progress in
                            if faults && row == 0 && progress.processedPositions > 0 { flags[row].cancel() }
                        }, onCheckpoint: { progress, stop, token in
                            if faults && row == 1 { throw RowFailure.checkpoint }
                            try await journals.accept(progress, identity: identity, stop: stop, token: token)
                        }, onText: { _ in })
                }
                let cohort = try manager.makeTextCohort(requests.indices.map {
                    .init(owner: requests[$0].owner, tokens: prompts[$0], joinedBinding: nil)
                }, prefill: .init(stepSize: 512), allowSnapshot: nil, admit: { _ in },
                    outputLimits: requests.map { $0.identity.maxTokens }, makeCache: { try model.newCache(parameters: nil) })
                defer { cohort.discard() }
                let origins = try MLXGemmaRunner.independentOrigins(requests: requests, preparedIDs: prompts,
                    cohort: cohort, policy: policy)
                do {
                    let decoded = try await MLXGemmaRunner.decodeIndependentText(requests: requests, model: model,
                        tokenizer: IDTokenizer(), cohort: cohort, origins: origins, policy: policy, flag: CancellationFlag())
                    // The exact local CPU producer has returned. Join submitted
                    // arrays and real spill work before destroying their owner.
                    Stream.defaultStream.synchronize()
                    await manager.joinTextCohortSpill(cohort, cancelled: false)
                    let dispositions: [PromptPrefixCache.TextCohortRetention?] = requests.indices.map { row in
                        if case .failure = decoded.outputs[row] { return nil }
                        return .init(completion: decoded.completions[row], acknowledged: decoded.acknowledged[row],
                            proof: nil, authorization: nil)
                    }
                    #expect(manager.publishTextCohort(cohort, retention: dispositions))
                    let retained = manager.retainedSnapshotObservations
                    #expect(!retained.isEmpty)
                    for value in retained {
                        let row = try #require(value.row)
                        #expect(requests.indices.contains(row))
                        guard requests.indices.contains(row) else { continue }
                        #expect(dispositions[row] != nil)
                        #expect(value.namespace == requests[row].owner.namespace)
                        #expect(value.nativePhysicalWidth == requests.count)
                    }
                    if faults {
                        #expect(retained.contains { $0.row == 2 && $0.namespace == requests[2].owner.namespace })
                        #expect(!retained.contains { $0.row == 0 || $0.row == 1 })
                    }
                    cohort.discard()
                    manager.clear(reason: "public_cpu_control_joined")
                    await manager.joinTextCohortSpill(cohort, cancelled: true)
                    return (decoded, requests, origins)
                } catch {
                    Stream.defaultStream.synchronize()
                    await manager.joinTextCohortSpill(cohort, cancelled: true)
                    throw error
                }
            }
            let (baseline, _, _) = try await run(faults: false)
            let (faulted, requests, origins) = try await run(faults: true)
            #expect(try baseline.outputs[2].get().outputTokens > 0)
            #expect(faulted.cancelled == [true, false, false])
            #expect(faulted.checkpointUncertain == [false, true, false])
            if case .failure(let error) = faulted.outputs[0] { #expect(error is CancellationError) }
            else { Issue.record("Cancelled actual row returned success") }
            if case .failure(let error) = faulted.outputs[1] { #expect(error is RowFailure) }
            else { Issue.record("Refused actual row checkpoint returned success") }
            let peer = try faulted.outputs[2].get(), expected = try baseline.outputs[2].get()
            #expect(peer.tokenIDs == expected.tokenIDs && peer.stopReason == expected.stopReason)
            let journal = try #require(await journals.value(requests[2].identity.attemptID))
            #expect(journal.identity == requests[2].identity)
            #expect(journal.progress.tokenIDs == peer.tokenIDs)
            let document = DocumentSnapshot(title: "Fixture", text: "1 ")
            let recipe = CompletionRecipe(document: document, caretUTF16: 2, sources: [],
                prompt: "independent-question-2", promptDigest: requests[2].identity.requestDigest,
                omittedPrefixCharacters: 0, model: requests[2].identity.model, profile: .standard,
                settings: requests[2].settings, maxTokens: 4, generationPolicy: policy)
            let candidate = WritingCandidate(id: requests[2].identity.attemptID, seed: seeds[2],
                text: peer.text, state: .complete, promptTokens: peer.promptTokens,
                outputTokens: peer.outputTokens, tokenIDs: peer.tokenIDs, stopReason: peer.stopReason,
                executionOrigin: peer.executionOrigin)
            #expect(throws: BoomError.self) {
                try candidate.coldReplayPolicy(recipe: recipe, loadedModel: recipe.model, loadedPolicy: policy)
            }
            #expect(await journals.value(requests[1].identity.attemptID) == nil)
            for row in requests.indices {
                let origin = try #require(origins[row].independentCohort)
                #expect(origin.row == row && origin.rows[row].namespace == requests[row].owner.namespace)
                #expect(origin.rows[row].seed == seeds[row] && origin.rows[row].attemptID == requests[row].identity.attemptID)
                #expect(!origins[row].isConfirmedCold(promptTokens: prompts[row].count))
            }
        }
    }
}
