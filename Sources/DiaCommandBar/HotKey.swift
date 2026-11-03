import Carbon

/// Carbon のグローバルホットキー（アクセシビリティ権限不要）。
/// register / unregister を切り替えることで「Dia が前面のときだけ」奪う。
final class HotKey {
    static var onPress: (() -> Void)?
    private static var handlerInstalled = false

    private let keyCode: UInt32
    private let modifiers: UInt32
    private var ref: EventHotKeyRef?

    init(keyCode: Int, modifiers: Int) {
        self.keyCode = UInt32(keyCode)
        self.modifiers = UInt32(modifiers)
        Self.installHandlerIfNeeded()
    }

    var isRegistered: Bool { ref != nil }

    func register() {
        guard ref == nil else { return }
        let hotKeyID = EventHotKeyID(signature: OSType(0x4443_4231) /* 'DCB1' */, id: 1)
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetEventDispatcherTarget(), 0, &ref)
        if status != noErr {
            NSLog("[DiaCommandBar] RegisterEventHotKey failed: \(status)")
            ref = nil
        }
    }

    func unregister() {
        guard let ref else { return }
        UnregisterEventHotKey(ref)
        self.ref = nil
    }

    private static func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, _, _ in
            HotKey.onPress?()
            return noErr
        }, 1, &spec, nil, nil)
        handlerInstalled = true
    }
}
