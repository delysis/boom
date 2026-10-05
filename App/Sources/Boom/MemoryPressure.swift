import Foundation

final class MemoryPressureWatch {
  private let source: DispatchSourceMemoryPressure
  init(onPressure: @escaping @Sendable (Bool) -> Void) {
    source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global(qos: .utility))
    let captured = source
    source.setEventHandler { onPressure(captured.data.contains(.critical)) }
    source.resume()
  }
  deinit { source.cancel() }
}
