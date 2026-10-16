#if BLOOM_DEVELOPER_STACK_DIAGNOSTICS
import Darwin
import Foundation
import MachO

/// Developer transport only. Phase producers never call this API. All Mach
/// work runs during explicit registration or on the bounded utility drain.
enum DeveloperStackWire {
  static let version: UInt32 = 2
  static let messageID: Int32 = 0x42534b32
  static let prefixBytes = 128
  static let phaseBytes = 64
  static let phasesPerMessage = 32
  static let messageBytes = prefixBytes + phasesPerMessage * phaseBytes
  static let receiveBytes = prefixBytes + 256
  static let maximumThreads = 8
  static let ringRecords = 512

  enum Tag: UInt32 { case hello = 10, challenge = 11, target = 12, thread = 13, phases = 14, loss = 15, ready = 16, done = 17 }
  enum Role: UInt32, Codable { case main = 1, inference = 2, storage = 3, editorWorker = 4 }
  enum PhaseKind: UInt16 { case begin = 1, end = 2, event = 3, progress = 4, unknownStage = 5 }
  enum Failure: Error { case admission, identity, layout, transport, deadline, exhausted }

  struct Identity: Codable, Equatable, Sendable {
    let pid: UInt32
    let ppid: UInt32
    let uid: UInt32
    let pgid: UInt32
    let startSeconds: UInt64
    let startMicroseconds: UInt32

    static func current(_ pid: pid_t) throws -> Self {
      guard pid > 1 else { throw Failure.identity }
      var info = proc_bsdinfo()
      let size = MemoryLayout<proc_bsdinfo>.size
      let read = withUnsafeMutablePointer(to: &info) {
        proc_pidinfo(pid, Int32(PROC_PIDTBSDINFO), 0, $0, Int32(size))
      }
      guard read == Int32(size), info.pbi_pid == UInt32(pid), info.pbi_start_tvusec < 1_000_000 else {
        throw Failure.identity
      }
      return Self(pid: info.pbi_pid, ppid: info.pbi_ppid, uid: info.pbi_uid,
        pgid: info.pbi_pgid, startSeconds: info.pbi_start_tvsec,
        startMicroseconds: UInt32(info.pbi_start_tvusec))
    }

    /// PPID and group may change after reparenting. Lifetime admission does not.
    func sameLifetime(as value: Self) -> Bool {
      pid == value.pid && uid == value.uid && startSeconds == value.startSeconds
        && startMicroseconds == value.startMicroseconds
    }
  }

  /// Eight scalar words, copied only by the utility consumer. No object, text,
  /// paths, registers or caller-provided buffers can enter a phase record.
  struct Phase: Sendable {
    var sequence: UInt64 = 0
    var correlationSequence: UInt64 = 0
    var correlationTID: UInt64 = 0
    var timestampTicks: UInt64 = 0
    var event: UInt64 = 0
    var emitterTID: UInt64 = 0
    var stage: UInt32 = 0
    var kind: UInt16 = 0
    var reserved: UInt16 = 0
    var value: UInt64 = 0
  }

  static func threadID(_ port: mach_port_t) throws -> UInt64 {
    var info = thread_identifier_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<thread_identifier_info_data_t>.size / 4)
    let expected = count
    let result = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        thread_info(port, thread_flavor_t(THREAD_IDENTIFIER_INFO), $0, &count)
      }
    }
    guard result == KERN_SUCCESS, count == expected, info.thread_id != 0 else {
      throw Failure.identity
    }
    return info.thread_id
  }

  /// The SDK does not expose servers/bootstrap.h through Darwin's Swift module.
  /// Resolve exactly this public libSystem function with its checked C signature;
  /// do not add a product C target or load another library. No symbolication.
  private static func lookup(_ service: String) throws -> mach_port_t {
    typealias Lookup = @convention(c) (
      mach_port_t, UnsafePointer<CChar>, UnsafeMutablePointer<mach_port_t>
    ) -> kern_return_t
    guard service.utf8.count < 128, let image = dlopen(nil, RTLD_LAZY) else {
      throw Failure.transport
    }
    defer { dlclose(image) }
    guard let symbol = dlsym(image, "bootstrap_look_up") else { throw Failure.transport }
    let call = unsafeBitCast(symbol, to: Lookup.self)
    var bootstrap: mach_port_t = 0
    guard task_get_special_port(mach_task_self_, Int32(TASK_BOOTSTRAP_PORT), &bootstrap)
      == KERN_SUCCESS else { throw Failure.transport }
    defer { mach_port_deallocate(mach_task_self_, bootstrap) }
    var owner: mach_port_t = 0
    let result = service.withCString { call(bootstrap, $0, &owner) }
    guard result == KERN_SUCCESS, owner != 0, owner != UInt32.max else {
      if owner != 0 && owner != UInt32.max { mach_port_deallocate(mach_task_self_, owner) }
      throw Failure.transport
    }
    return owner
  }

  final class Client: @unchecked Sendable {
    private let nonceLow: UInt64
    private let nonceHigh: UInt64
    private let own: Identity
    private let expectedParent: Identity
    private var reply: mach_port_t = 0
    private var replyHasSend = false
    private var owner: mach_port_t = 0
    private var authenticated = false
    // One Client is serialized outside the measured phase path by its Session.
    private var bytes = [UInt8](repeating: 0, count: messageBytes)
    private var received = [UInt8](repeating: 0, count: receiveBytes)

    init(nonce: [UInt8], own: Identity, parent: Identity) throws {
      guard nonce.count == 16, nonce.contains(where: { $0 != 0 }), own.ppid == parent.pid,
        own.uid == parent.uid, own.pgid == own.pid, own.pid != parent.pid,
        MemoryLayout<mach_msg_header_t>.size == 24,
        MemoryLayout<mach_msg_port_descriptor_t>.size == 12,
        MemoryLayout<mach_msg_audit_trailer_t>.size == 52,
        MemoryLayout<Phase>.size == phaseBytes else { throw Failure.layout }
      self.nonceLow = nonce[..<8].enumerated().reduce(0) { $0 | UInt64($1.element) << ($1.offset * 8) }
      self.nonceHigh = nonce[8...].enumerated().reduce(0) { $0 | UInt64($1.element) << ($1.offset * 8) }
      self.own = own; self.expectedParent = parent
      guard mach_port_allocate(mach_task_self_, mach_port_right_t(MACH_PORT_RIGHT_RECEIVE), &reply)
        == KERN_SUCCESS else { throw Failure.transport }
      do {
        guard mach_port_insert_right(mach_task_self_, reply, reply,
          mach_msg_type_name_t(MACH_MSG_TYPE_MAKE_SEND)) == KERN_SUCCESS else { throw Failure.transport }
        replyHasSend = true
        let hexadecimal = nonce.map { String(format: "%02x", $0) }.joined()
        owner = try Self.lookupOwner("com.delysis.bloom.stack-v2.\(hexadecimal).owner")
        // Only a send right for our anonymous reply port leaves before the
        // audit-token parent challenge. No task/thread authority is sent here.
        prepare(.hello, tid: 0, role: 0, value: 0, rights: [reply])
        try send(size: prefixBytes, timeout: 100)
        try challenge()
        authenticated = true
      } catch {
        release(); throw error
      }
    }

    private static func lookupOwner(_ service: String) throws -> mach_port_t {
      try DeveloperStackWire.lookup(service)
    }
    deinit { release() }
    private func release() {
      if owner != 0 { mach_port_deallocate(mach_task_self_, owner); owner = 0 }
      if reply != 0 {
        mach_port_mod_refs(mach_task_self_, reply, mach_port_right_t(MACH_PORT_RIGHT_RECEIVE), -1)
        if replyHasSend { mach_port_deallocate(mach_task_self_, reply) }
        reply = 0; replyHasSend = false
      }
    }

    private func put<T: FixedWidthInteger>(_ value: T, at offset: Int) {
      var little = value.littleEndian
      withUnsafeBytes(of: &little) { source in
        bytes.withUnsafeMutableBytes { $0.baseAddress!.advanced(by: offset).copyMemory(
          from: source.baseAddress!, byteCount: source.count) }
      }
    }
    private func prepare(_ tag: Tag, tid: UInt64, role: UInt32, value: UInt64,
      rights: [mach_port_t] = []) {
      bytes.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
      put(UInt32(MACH_MSG_TYPE_COPY_SEND) | (rights.isEmpty ? 0 : UInt32(MACH_MSGH_BITS_COMPLEX)), at: 0)
      put(owner, at: 8); put(messageID, at: 20)
      put(UInt32(rights.count), at: 24)
      for (index, port) in rights.enumerated() {
        let at = 28 + index * 12
        put(port, at: at); bytes[at + 10] = UInt8(MACH_MSG_TYPE_COPY_SEND)
        bytes[at + 11] = UInt8(MACH_MSG_PORT_DESCRIPTOR)
      }
      put(version, at: 64); put(tag.rawValue, at: 68); put(own.pid, at: 72)
      put(role, at: 76); put(tid, at: 80); put(value, at: 88)
      put(nonceLow, at: 96); put(nonceHigh, at: 104)
      put(own.startSeconds, at: 112); put(own.startMicroseconds, at: 120)
    }
    private func send(size: Int, timeout: UInt32) throws {
      guard (prefixBytes...messageBytes).contains(size) else { throw Failure.layout }
      put(UInt32(size), at: 4)
      let status = bytes.withUnsafeMutableBytes {
        mach_msg($0.baseAddress!.assumingMemoryBound(to: mach_msg_header_t.self),
          mach_msg_option_t(MACH_SEND_MSG | MACH_SEND_TIMEOUT), mach_msg_size_t(size),
          0, 0, timeout, 0)
      }
      guard status == MACH_MSG_SUCCESS else { throw Failure.transport }
    }
    private func challenge(tag: Tag = .challenge, value: UInt64 = 0) throws {
      let status = received.withUnsafeMutableBytes {
        mach_msg($0.baseAddress!.assumingMemoryBound(to: mach_msg_header_t.self),
          mach_msg_option_t(MACH_RCV_MSG | MACH_RCV_TIMEOUT) | mach_msg_option_t(MACH_RCV_TRAILER_AUDIT) << 24,
          0, mach_msg_size_t(receiveBytes), reply, 10_000, 0)
      }
      guard status == MACH_MSG_SUCCESS else { throw Failure.deadline }
      func number<T: FixedWidthInteger>(_ offset: Int, _: T.Type) -> T {
        received.withUnsafeBytes { T(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: T.self)) }
      }
      let valid = number(4, UInt32.self) == UInt32(prefixBytes) && number(20, Int32.self) == messageID
        && number(24, UInt32.self) == 0 && number(0, UInt32.self) & UInt32(MACH_MSGH_BITS_COMPLEX) == 0
        && number(64, UInt32.self) == version && number(68, UInt32.self) == tag.rawValue
        && number(72, UInt32.self) == expectedParent.pid && number(76, UInt32.self) == 0
        && number(80, UInt64.self) == 0 && number(88, UInt64.self) == value
        && number(96, UInt64.self) == nonceLow && number(104, UInt64.self) == nonceHigh
        && number(112, UInt64.self) == expectedParent.startSeconds
        && number(120, UInt32.self) == expectedParent.startMicroseconds && number(124, UInt32.self) == 0
      let trailer = received.withUnsafeBytes {
        $0.loadUnaligned(fromByteOffset: prefixBytes, as: mach_msg_audit_trailer_t.self)
      }
      guard valid, trailer.msgh_trailer_type == MACH_MSG_TRAILER_FORMAT_0,
        trailer.msgh_trailer_size == UInt32(MemoryLayout<mach_msg_audit_trailer_t>.size),
        audit_token_to_pid(trailer.msgh_audit) == pid_t(expectedParent.pid),
        audit_token_to_euid(trailer.msgh_audit) == expectedParent.uid,
        try Identity.current(pid_t(expectedParent.pid)).sameLifetime(as: expectedParent) else {
        received.withUnsafeMutableBytes {
          mach_msg_destroy($0.baseAddress!.assumingMemoryBound(to: mach_msg_header_t.self))
        }
        throw Failure.identity
      }
    }

    func donateCurrentThread(role: Role) throws -> UInt64 {
      guard authenticated,
        try Identity.current(pid_t(expectedParent.pid)).sameLifetime(as: expectedParent),
        try Identity.current(getpid()) == own else { throw Failure.identity }
      if role == .main, pthread_main_np() != 1 { throw Failure.identity }
      let thread = mach_thread_self()
      guard thread != 0 else { throw Failure.identity }
      defer { mach_port_deallocate(mach_task_self_, thread) }
      let tid = try DeveloperStackWire.threadID(thread)
      let base: UInt64
      if role == .main {
        guard let header = _dyld_get_image_header(0) else { throw Failure.identity }
        base = UInt64(UInt(bitPattern: header))
      } else { base = 0 }
      prepare(role == .main ? .target : .thread, tid: tid, role: role.rawValue, value: base,
        rights: role == .main ? [mach_task_self_, thread, reply] : [thread])
      try send(size: prefixBytes, timeout: 100)
      return tid
    }

    /// Root prepares/adopts modules and starts its sampler before this start
    /// signal. A fast fixture cannot race ahead of stack collection readiness.
    func waitForStart() throws {
      guard authenticated else { throw Failure.identity }
      try challenge(tag: .ready, value: 1)
    }
    func done(tid: UInt64, lastSequence: UInt64) throws {
      guard authenticated else { throw Failure.identity }
      prepare(.done, tid: tid, role: Role.main.rawValue, value: lastSequence)
      // Outside all measured phases. One bounded send gives the parent room to
      // drain the final burst; there is no retry or unbounded termination wait.
      try send(size: prefixBytes, timeout: 100)
      try challenge(tag: .ready, value: 2) // remain alive until sampler is joined.
    }

    /// Utility drain only; zero-timeout during measured work. Final shutdown
    /// alone may wait up to100ms after its sole producer has stopped.
    func phases(_ records: UnsafeBufferPointer<Phase>, tid: UInt64, role: Role, timeout: UInt32 = 0) throws {
      guard authenticated, (1...phasesPerMessage).contains(records.count), timeout <= 100 else { throw Failure.admission }
      prepare(.phases, tid: tid, role: role.rawValue, value: UInt64(records.count))
      for (index, phase) in records.enumerated() {
        let at = prefixBytes + index * phaseBytes
        put(phase.sequence, at: at); put(phase.correlationSequence, at: at + 8)
        put(phase.correlationTID, at: at + 16); put(phase.timestampTicks, at: at + 24)
        put(phase.event, at: at + 32); put(phase.emitterTID, at: at + 40)
        put(phase.stage, at: at + 48); put(phase.kind, at: at + 52)
        put(phase.reserved, at: at + 54); put(phase.value, at: at + 56)
      }
      try send(size: prefixBytes + records.count * phaseBytes, timeout: timeout)
    }
    func loss(tid: UInt64, role: Role, ringFull: UInt64, transport: UInt64,
      unregistered: UInt64, invalid: UInt64, exhausted: UInt64, lostSnapshots: UInt64, timeout: UInt32 = 0) throws {
      guard authenticated, timeout <= 100 else { throw Failure.admission }
      prepare(.loss, tid: tid, role: role.rawValue, value: ringFull)
      put(transport, at: prefixBytes); put(unregistered, at: prefixBytes + 8)
      put(invalid, at: prefixBytes + 16); put(exhausted, at: prefixBytes + 24)
      put(lostSnapshots, at: prefixBytes + 32)
      try send(size: prefixBytes + 40, timeout: timeout)
    }
  }
}
#endif
