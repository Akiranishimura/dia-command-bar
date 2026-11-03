import AppKit

/// ボーダーレスでもキーウィンドウになれる、アプリをアクティブにしないパネル。
/// Dia を前面のまま入力を受けられるので、⌘T の登録状態も変わらない。
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// メニューを持たないアプリなので、⌘A / ⌘C / ⌘V / ⌘X / ⌘Z は自前で入力欄に流す
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard mods == .command || mods == [.command, .shift] else { return super.performKeyEquivalent(with: event) }
        let action: Selector?
        switch (event.charactersIgnoringModifiers?.lowercased(), mods.contains(.shift)) {
        case ("a", false): action = #selector(NSText.selectAll(_:))
        case ("c", false): action = #selector(NSText.copy(_:))
        case ("v", false): action = #selector(NSText.paste(_:))
        case ("x", false): action = #selector(NSText.cut(_:))
        case ("z", false): action = Selector(("undo:"))
        case ("z", true): action = Selector(("redo:"))
        default: action = nil
        }
        if let action, NSApp.sendAction(action, to: nil, from: self) { return true }
        return super.performKeyEquivalent(with: event)
    }
}

/// IME の変換中（未確定）の文字列が変わったことを通知するフィールドエディタ。
/// NSTextField は未確定文字では controlTextDidChange を呼ばないので、日本語入力中も候補を出すために使う。
private final class FieldEditor: NSTextView {
    var onMarkedTextChange: (() -> Void)?

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        onMarkedTextChange?()
    }
}

/// 外観（ライト / ダーク）が変わるたびに色を塗り直すレイヤービュー
final class LayerView: NSView {
    var paint: (LayerView, Bool) -> Void = { _, _ in }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { paint(self, isDark) }
    var isDark: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
    func repaint() { needsDisplay = true }
}

/// 寸法は Arc 1.170 のコマンドバーを実測した値
private enum Metrics {
    static let width: CGFloat = 764
    static let inputHeight: CGFloat = 62
    static let rowHeight: CGFloat = 50
    static let listInset: CGFloat = 9
    static let listTop: CGFloat = 8
    static let listBottom: CGFloat = 8
    static let cornerRadius: CGFloat = 10
    /// 5 行表示のときにパネル全体がウィンドウの縦中央に来る（Arc と同じ）
    static let referenceHeight: CGFloat = inputHeight + 1 + 5 * rowHeight + listTop + listBottom
    static let openDuration: TimeInterval = 0.16
    static let closeDuration: TimeInterval = 0.09
    static let resizeDuration: TimeInterval = 0.12
    static let easeOut = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
}

final class CommandBarController: NSObject {
    private let panel: KeyablePanel
    private let background = LayerView()
    private let searchIcon = NSImageView()
    private let scopeChip = LayerView()
    private let scopeIcon = NSImageView()
    private let scopeLabel = NSTextField(labelWithString: "")
    private let field = NSTextField()
    private let separator = LayerView()
    private let scrollView = NSScrollView()
    private let tableView = HoverTableView()
    private let highlight = LayerView()
    private let fieldEditor: FieldEditor = {
        let e = FieldEditor()
        e.isFieldEditor = true
        e.allowsUndo = true
        return e
    }()
    private var fieldAfterIcon: NSLayoutConstraint!
    private var fieldAfterChip: NSLayoutConstraint!

    private var rows: [Suggestion] = []
    private var selectedIndex = 0
    private var userMovedSelection = false
    private var scope: SearchEngine?
    /// ユーザーが実際に打った文字列（インライン補完を含まない）
    private var userText = ""
    private var ctx = SuggestionContext()
    private let data = BrowserData()
    private let suggestClient = SearchSuggestClient()

    // 表示中のパネル位置（上端と横位置は固定し、高さだけ変える）
    private var anchorTop: CGFloat = 0
    private var anchorX: CGFloat = 0
    private var panelWidth: CGFloat = Metrics.width
    private var closeGeneration = 0

    var isVisible: Bool { panel.isVisible && panel.alphaValue > 0 }

    override init() {
        panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: Metrics.width, height: Metrics.inputHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        super.init()
        configurePanel()
        if DemoData.isEnabled { ctx = DemoData.context() }
    }

    // MARK: - Show / Hide

    func toggle() {
        isVisible ? hide() : show()
    }

    func show() {
        closeGeneration += 1
        field.stringValue = ""
        userText = ""
        setScope(nil, rebuild: false)
        ctx.searchPhrases = ("", [])
        userMovedSelection = false
        rows = Ranker.build(text: "", userText: "", scope: nil, ctx)
        selectedIndex = 0
        tableView.reloadData()
        layoutAnchor()

        let target = frame(forHeight: panelHeight())
        separator.isHidden = rows.isEmpty
        // 少し小さく・少し上から、ふわっと出す
        panel.setFrame(target.insetBy(dx: 12, dy: 5).offsetBy(dx: 0, dy: 6), display: false)
        panel.alphaValue = 0
        // ホットキーハンドラ内で同期的に key にするので、直後のキー入力はこのパネルに届く
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        updateHighlight(animated: false)
        NSAnimationContext.runAnimationGroup({ c in
            c.duration = Metrics.openDuration
            c.timingFunction = Metrics.easeOut
            panel.animator().setFrame(target, display: true)
            panel.animator().alphaValue = 1
        }, completionHandler: { [weak self] in self?.panel.invalidateShadow() })
        refreshState()
    }

    func hide() {
        guard panel.isVisible else { return }
        suggestClient.cancel()
        closeGeneration += 1
        let generation = closeGeneration
        NSAnimationContext.runAnimationGroup({ c in
            c.duration = Metrics.closeDuration
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.closeGeneration == generation else { return }
            self.panel.orderOut(nil)
        })
    }

    /// タブ一覧・履歴を最新にする（Dia が前面に来たとき＆パネルを開いたとき）
    func refreshState() {
        if DemoData.isEnabled {
            let phrases = ctx.searchPhrases
            ctx = DemoData.context()
            ctx.searchPhrases = phrases
            return
        }
        DiaBridge.fetchState { [weak self] state in
            guard let self, let state else { return }
            self.ctx.tabs = state.tabs
            self.ctx.activeSpace = state.activeSpace
            self.ctx.activeTabID = state.activeTabID
            self.ctx.spaces = state.spaces
            self.applyHistory()
            if self.isVisible { self.rebuildRows() }
            self.data.refreshIfNeeded { [weak self] in
                guard let self else { return }
                self.applyHistory()
                if self.isVisible { self.rebuildRows() }
            }
        }
    }

    private func applyHistory() {
        let urls = ctx.tabs.filter { $0.space == ctx.activeSpace }.map(\.url)
        guard let h = data.history(forSpace: ctx.activeSpace, tabURLs: urls) else { return }
        ctx.history = h.entries
        ctx.lastVisitByURL = h.lastVisitByURL
        ctx.hostRank = h.hostRank
    }

    // MARK: - Setup

    private func configurePanel() {
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.delegate = self
        fieldEditor.onMarkedTextChange = { [weak self] in self?.inputChanged(allowCompletion: false) }

        // 不透明な角丸の背景（半透明マテリアルだと四角い枠が出るのでやめた）
        background.wantsLayer = true
        background.paint = { v, dark in
            v.layer?.cornerRadius = Metrics.cornerRadius
            v.layer?.cornerCurve = .continuous
            v.layer?.masksToBounds = true
            v.layer?.borderWidth = 1
            v.layer?.backgroundColor = (dark ? NSColor(srgbRed: 0.106, green: 0.106, blue: 0.11, alpha: 1)
                                             : NSColor(srgbRed: 0.99, green: 0.99, blue: 0.99, alpha: 1)).cgColor
            v.layer?.borderColor = (dark ? NSColor(white: 1, alpha: 0.13) : NSColor(white: 0, alpha: 0.12)).cgColor
        }
        panel.contentView = background

        searchIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        searchIcon.symbolConfiguration = .init(pointSize: 14, weight: .semibold)
        searchIcon.contentTintColor = .secondaryLabelColor

        scopeChip.wantsLayer = true
        scopeChip.paint = { v, dark in
            v.layer?.cornerRadius = 6
            v.layer?.backgroundColor = (dark ? NSColor(white: 1, alpha: 0.12) : NSColor(white: 0, alpha: 0.07)).cgColor
        }
        scopeIcon.imageScaling = .scaleProportionallyDown
        scopeLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        let chipStack = NSStackView(views: [scopeIcon, scopeLabel])
        chipStack.spacing = 6
        chipStack.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 9)
        chipStack.translatesAutoresizingMaskIntoConstraints = false
        scopeChip.addSubview(chipStack)
        scopeChip.isHidden = true

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 17)
        field.placeholderString = "検索、または URL を入力…"
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = self

        separator.wantsLayer = true
        separator.paint = { v, dark in
            v.layer?.backgroundColor = (dark ? NSColor(white: 1, alpha: 0.08) : NSColor(white: 0, alpha: 0.08)).cgColor
        }

        let column = NSTableColumn(identifier: .init("main"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.headerView = nil
        tableView.rowHeight = Metrics.rowHeight
        tableView.intercellSpacing = .zero
        tableView.backgroundColor = .clear
        tableView.style = .plain
        tableView.selectionHighlightStyle = .none
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(rowClicked)
        tableView.refusesFirstResponder = true
        tableView.onHoverRow = { [weak self] row in self?.hoverRow(row) }

        highlight.wantsLayer = true
        highlight.paint = { v, dark in
            v.layer?.cornerRadius = 8
            v.layer?.cornerCurve = .continuous
            v.layer?.backgroundColor = (dark ? NSColor(srgbRed: 0.45, green: 0.47, blue: 0.56, alpha: 0.7)
                                             : NSColor(srgbRed: 0.25, green: 0.35, blue: 0.6, alpha: 0.14)).cgColor
        }
        tableView.addSubview(highlight, positioned: .below, relativeTo: nil)

        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.verticalScrollElasticity = .none
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: Metrics.listTop, left: 0, bottom: Metrics.listBottom, right: 0)

        for v in [searchIcon, scopeChip, field, separator, scrollView] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            background.addSubview(v)
        }
        fieldAfterIcon = field.leadingAnchor.constraint(equalTo: searchIcon.trailingAnchor, constant: 12)
        fieldAfterChip = field.leadingAnchor.constraint(equalTo: scopeChip.trailingAnchor, constant: 8)
        let inputCenter = background.topAnchor
        NSLayoutConstraint.activate([
            searchIcon.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 24),
            searchIcon.centerYAnchor.constraint(equalTo: inputCenter, constant: Metrics.inputHeight / 2),
            searchIcon.widthAnchor.constraint(equalToConstant: 16),
            scopeChip.leadingAnchor.constraint(equalTo: searchIcon.trailingAnchor, constant: 10),
            scopeChip.centerYAnchor.constraint(equalTo: searchIcon.centerYAnchor),
            chipStack.leadingAnchor.constraint(equalTo: scopeChip.leadingAnchor),
            chipStack.trailingAnchor.constraint(equalTo: scopeChip.trailingAnchor),
            chipStack.topAnchor.constraint(equalTo: scopeChip.topAnchor),
            chipStack.bottomAnchor.constraint(equalTo: scopeChip.bottomAnchor),
            scopeIcon.widthAnchor.constraint(equalToConstant: 14),
            scopeIcon.heightAnchor.constraint(equalToConstant: 14),
            fieldAfterIcon,
            field.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -24),
            field.centerYAnchor.constraint(equalTo: searchIcon.centerYAnchor),
            separator.topAnchor.constraint(equalTo: background.topAnchor, constant: Metrics.inputHeight),
            separator.heightAnchor.constraint(equalToConstant: 1),
            separator.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: separator.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: Metrics.listInset),
            scrollView.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -Metrics.listInset),
            scrollView.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
    }

    // MARK: - Layout

    /// Arc と同じく Dia の最前面ウィンドウの中央に置く（取れなければマウスのある画面の中央）
    private func layoutAnchor() {
        let mouse = NSEvent.mouseLocation
        let window = DiaProfiles.frontWindowFrame()
        let screen = NSScreen.screens.first { s in
            if let w = window { return s.frame.contains(NSPoint(x: w.midX, y: w.midY)) }
            return NSMouseInRect(mouse, s.frame, false)
        } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let area = window.map { $0.intersection(visible) } ?? visible

        panelWidth = min(Metrics.width, area.width - 80)
        anchorX = area.midX - panelWidth / 2
        let maxHeight = Metrics.inputHeight + 1 + CGFloat(Ranker.maxRows) * Metrics.rowHeight + Metrics.listTop + Metrics.listBottom
        anchorTop = area.midY + Metrics.referenceHeight / 2
        anchorTop = min(anchorTop, visible.maxY - 20)
        anchorTop = max(anchorTop, visible.minY + 20 + maxHeight)
    }

    private func panelHeight() -> CGFloat {
        guard !rows.isEmpty else { return Metrics.inputHeight }
        return Metrics.inputHeight + 1 + CGFloat(rows.count) * Metrics.rowHeight + Metrics.listTop + Metrics.listBottom
    }

    private func frame(forHeight h: CGFloat) -> NSRect {
        NSRect(x: anchorX, y: anchorTop - h, width: panelWidth, height: h)
    }

    private func resizeToFitRows() {
        let target = frame(forHeight: panelHeight())
        separator.isHidden = rows.isEmpty
        guard target != panel.frame else { return }
        NSAnimationContext.runAnimationGroup({ c in
            c.duration = Metrics.resizeDuration
            c.timingFunction = Metrics.easeOut
            panel.animator().setFrame(target, display: true)
        }, completionHandler: { [weak self] in self?.panel.invalidateShadow() })
    }

    private func updateHighlight(animated: Bool) {
        guard rows.indices.contains(selectedIndex) else {
            highlight.isHidden = true
            return
        }
        // reloadData で行ビューが前に積まれるので、常に最背面に戻す
        if tableView.subviews.first !== highlight {
            highlight.removeFromSuperview()
            tableView.addSubview(highlight, positioned: .below, relativeTo: nil)
        }
        let target = NSRect(x: 0, y: CGFloat(selectedIndex) * Metrics.rowHeight,
                            width: max(tableView.bounds.width, panelWidth - Metrics.listInset * 2), height: Metrics.rowHeight)
        // 選択の移動はアニメーションさせない（Arc と同じく即座に切り替える）
        highlight.isHidden = false
        highlight.frame = target
        for row in rows.indices {
            (tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? SuggestionCell)?.setSelected(row == selectedIndex)
        }
    }

    // MARK: - Scope (Tab to search)

    private func setScope(_ engine: SearchEngine?, rebuild: Bool = true) {
        scope = engine
        if let engine {
            scopeLabel.stringValue = engine.name
            scopeIcon.image = data.cachedFavicon(for: engine.home)
                ?? NSImage(systemSymbolName: engine.isAI ? "sparkles" : "magnifyingglass", accessibilityDescription: nil)
            data.loadFavicon(for: engine.home) { [weak self] in
                guard let self, self.scope == engine else { return }
                self.scopeIcon.image = self.data.cachedFavicon(for: engine.home)
            }
            field.placeholderString = "\(engine.actionLabel)…"
            fieldAfterIcon.isActive = false
            fieldAfterChip.isActive = true
            scopeChip.isHidden = false
            scopeChip.alphaValue = 0
            NSAnimationContext.runAnimationGroup { c in
                c.duration = 0.12
                scopeChip.animator().alphaValue = 1
            }
        } else {
            field.placeholderString = "検索、または URL を入力…"
            fieldAfterChip.isActive = false
            fieldAfterIcon.isActive = true
            scopeChip.isHidden = true
        }
        guard rebuild else { return }
        editor?.string = ""
        userText = ""
        ctx.searchPhrases = ("", [])
        userMovedSelection = false
        rebuildRows()
    }

    // MARK: - Suggestions

    private var editor: NSTextView? { field.currentEditor() as? NSTextView }
    private var currentText: String { editor?.string ?? field.stringValue }

    private func rebuildRows() {
        let previous = rows.indices.contains(selectedIndex) ? rows[selectedIndex] : nil
        rows = Ranker.build(text: currentText, userText: userText, scope: scope, ctx)
        if userMovedSelection, let previous, let i = rows.firstIndex(of: previous) {
            selectedIndex = i
        } else {
            userMovedSelection = false
            selectedIndex = 0
        }
        tableView.reloadData()
        resizeToFitRows()
        updateHighlight(animated: false)
    }

    private func moveSelection(_ delta: Int) {
        guard !rows.isEmpty else { return }
        selectedIndex = (selectedIndex + delta + rows.count) % rows.count
        userMovedSelection = true
        updateHighlight(animated: true)
    }

    private func hoverRow(_ row: Int) {
        guard rows.indices.contains(row), row != selectedIndex else { return }
        selectedIndex = row
        userMovedSelection = true
        updateHighlight(animated: true)
    }

    /// ドメインのインライン補完（"gi" → "gi|thub.com" の補完部分を選択状態で入れる）
    private func applyInlineCompletion() {
        guard scope == nil, let editor, !editor.hasMarkedText(),
              let completion = Ranker.inlineCompletion(for: userText, ctx) else { return }
        let typedLength = (userText as NSString).length
        editor.string = userText + completion
        editor.setSelectedRange(NSRange(location: typedLength, length: (completion as NSString).length))
    }

    private var hasInlineCompletion: Bool {
        guard let editor else { return false }
        let r = editor.selectedRange()
        return r.length > 0 && NSMaxRange(r) == (editor.string as NSString).length && currentText != userText
    }

    // MARK: - Execute

    private func executeSelection() {
        // 選択を動かしていなければ、いまの入力から候補を同期的に作り直して先頭を実行する。
        // サジェストの非同期更新を待たないので、Enter 直前に打った文字が落ちない。
        if !userMovedSelection {
            rows = Ranker.build(text: currentText, userText: userText, scope: scope, ctx)
            selectedIndex = 0
        }
        guard rows.indices.contains(selectedIndex) else { return }
        let suggestion = rows[selectedIndex]
        if case .enterScope(let engine) = suggestion.action {
            setScope(engine)
            return
        }
        hide()
        switch suggestion.action {
        case .open(let url): DiaBridge.openInNewTab(url)
        case .switchTab(let tab): DiaBridge.focusTab(tab)
        case .focusSpace(let name): DiaBridge.focusSpace(name)
        case .copyURL:
            if let url = DiaBridge.activeTabURL(), !url.isEmpty {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url, forType: .string)
            }
        case .closeTab: DiaBridge.closeActiveTab()
        case .duplicateTab: DiaBridge.duplicateActiveTab()
        case .enterScope: break
        }
    }

    @objc private func rowClicked() {
        let row = tableView.clickedRow
        guard rows.indices.contains(row) else { return }
        selectedIndex = row
        userMovedSelection = true
        executeSelection()
    }
}

// MARK: - NSTextFieldDelegate

extension CommandBarController: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        inputChanged(allowCompletion: true)
    }

    /// 確定した入力・IME の未確定入力のどちらでも呼ばれる
    fileprivate func inputChanged(allowCompletion: Bool) {
        let text = currentText
        // 1 文字ずつ打ち足しているときだけ補完する（削除中・IME 変換中はしない）
        let grew = text.count > userText.count && text.hasPrefix(userText)
        // 未確定文字の通知は変化がなければ無視（確定・削除時は補完を消した場合もあるので常に作り直す）
        if !allowCompletion && text == userText { return }
        userText = text
        if grew && allowCompletion { applyInlineCompletion() }
        userMovedSelection = false
        rebuildRows()
        guard !DemoData.isEnabled else { return } // スクリーンショット用: 実際のサジェストは出さない
        let query = text
        suggestClient.fetch(query) { [weak self] q, phrases in
            guard let self, self.isVisible, q == self.userText else { return } // 古い応答は捨てる
            self.ctx.searchPhrases = (q, phrases)
            self.rebuildRows()
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        // IME 変換中の Enter / 矢印はここに来ない（変換確定に使われる）ので特別扱い不要
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            executeSelection(); return true
        case #selector(NSResponder.cancelOperation(_:)):
            if scope != nil { setScope(nil) } else { hide() }
            return true
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(1); return true
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(-1); return true
        case #selector(NSResponder.insertTab(_:)):
            if scope == nil, let engine = SearchEngine.matching(userText) {
                setScope(engine)
            } else if hasInlineCompletion {
                textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
                userText = textView.string
                rebuildRows()
            }
            return true
        case #selector(NSResponder.deleteBackward(_:)):
            if scope != nil && currentText.isEmpty {
                setScope(nil)
                return true
            }
            return false
        default:
            return false
        }
    }
}

// MARK: - NSWindowDelegate

extension CommandBarController: NSWindowDelegate {
    func windowDidResignKey(_ notification: Notification) { hide() }

    func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? {
        (client as? NSTextField) === field ? fieldEditor : nil
    }
}

// MARK: - Table

extension CommandBarController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = (tableView.makeView(withIdentifier: SuggestionCell.identifier, owner: nil) as? SuggestionCell) ?? SuggestionCell()
        let s = rows[row]
        var image: NSImage?
        if let page = s.faviconURL {
            image = data.cachedFavicon(for: page)
            if image == nil {
                data.loadFavicon(for: page) { [weak self] in
                    guard let self else { return }
                    let host = Ranker.bareHost(page)
                    let indexes = IndexSet(self.rows.indices.filter { self.rows[$0].faviconURL.map(Ranker.bareHost) == host })
                    self.tableView.reloadData(forRowIndexes: indexes, columnIndexes: [0])
                    self.updateHighlight(animated: false)
                }
            }
        }
        let showSubtitle = !currentText.trimmingCharacters(in: .whitespaces).isEmpty
        cell.configure(s, favicon: image, showSubtitle: showSubtitle, selected: row == selectedIndex)
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        ClearRowView()
    }
}

/// マウスを動かした行を選択するためのテーブル（パネルは非アクティブなので activeAlways）
private final class HoverTableView: NSTableView {
    var onHoverRow: ((Int) -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        if row >= 0 { onHoverRow?(row) }
    }
}

private final class ClearRowView: NSTableRowView {
    override func drawBackground(in dirtyRect: NSRect) {}
    override func drawSelection(in dirtyRect: NSRect) {}
}

private final class SuggestionCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("SuggestionCell")
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let actionLabel = NSTextField(labelWithString: "")
    private let arrowBox = LayerView()
    private let arrow = NSImageView()
    private var isSelectedRow = false

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier

        icon.imageScaling = .scaleProportionallyDown
        icon.symbolConfiguration = .init(pointSize: 13, weight: .medium)

        title.font = .systemFont(ofSize: 13.5, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        subtitle.font = .systemFont(ofSize: 12.5)
        subtitle.textColor = .tertiaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail
        actionLabel.font = .systemFont(ofSize: 12.5, weight: .semibold)
        actionLabel.lineBreakMode = .byTruncatingTail
        actionLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subtitle.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)

        arrowBox.wantsLayer = true
        arrowBox.paint = { [weak self] v, dark in
            let selected = self?.isSelectedRow ?? false
            v.layer?.cornerRadius = 5
            v.layer?.borderWidth = 1
            if dark {
                v.layer?.backgroundColor = NSColor(white: 1, alpha: selected ? 0.14 : 0.05).cgColor
                v.layer?.borderColor = NSColor(white: 1, alpha: selected ? 0.75 : 0.14).cgColor
            } else {
                v.layer?.backgroundColor = NSColor(white: 0, alpha: selected ? 0.06 : 0.03).cgColor
                v.layer?.borderColor = NSColor(white: 0, alpha: selected ? 0.45 : 0.1).cgColor
            }
        }
        arrow.image = NSImage(systemSymbolName: "arrow.right", accessibilityDescription: nil)
        arrow.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
        arrow.translatesAutoresizingMaskIntoConstraints = false
        arrowBox.addSubview(arrow)

        let text = NSStackView(views: [title, subtitle])
        text.orientation = .horizontal
        text.spacing = 8
        text.alignment = .firstBaseline
        for v in [icon, text, actionLabel, arrowBox] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 13),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 13),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            text.trailingAnchor.constraint(lessThanOrEqualTo: actionLabel.leadingAnchor, constant: -16),
            arrowBox.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            arrowBox.centerYAnchor.constraint(equalTo: centerYAnchor),
            arrowBox.widthAnchor.constraint(equalToConstant: 22),
            arrowBox.heightAnchor.constraint(equalToConstant: 22),
            arrow.centerXAnchor.constraint(equalTo: arrowBox.centerXAnchor),
            arrow.centerYAnchor.constraint(equalTo: arrowBox.centerYAnchor),
            actionLabel.trailingAnchor.constraint(equalTo: arrowBox.leadingAnchor, constant: -9),
            actionLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            actionLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 200),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ s: Suggestion, favicon: NSImage?, showSubtitle: Bool, selected: Bool) {
        if let favicon {
            icon.image = favicon
            icon.contentTintColor = nil
        } else {
            icon.image = NSImage(systemSymbolName: s.symbol, accessibilityDescription: nil)
            icon.contentTintColor = .secondaryLabelColor
        }
        title.stringValue = s.title
        subtitle.stringValue = s.subtitle ?? ""
        subtitle.isHidden = !showSubtitle || s.subtitle == nil
        actionLabel.stringValue = s.actionLabel
        actionLabel.isHidden = s.kind == .command
        isSelectedRow = !selected // setSelected で差分を検出させる
        setSelected(selected)
    }

    func setSelected(_ selected: Bool) {
        guard isSelectedRow != selected else { return }
        isSelectedRow = selected
        actionLabel.textColor = selected ? .labelColor : .tertiaryLabelColor
        arrow.contentTintColor = selected ? .labelColor : .tertiaryLabelColor
        arrowBox.repaint()
    }
}
