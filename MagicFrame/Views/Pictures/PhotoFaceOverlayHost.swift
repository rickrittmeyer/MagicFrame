import UIKit

/// Hosts per-face chrome on the zooming photo view so boxes track pinch/pan.
final class PhotoFaceOverlayHost: UIView {

    var onAssign: ((
        _ faceInstanceId: Int,
        _ displayName: String,
        _ firstName: String?,
        _ lastName: String?,
        _ maidenName: String?
    ) -> Void)?

    /// Called when the user starts naming a face — image-space face rect for zoom/pan focus.
    var onBeginEditingFace: ((_ faceInstanceId: Int, _ faceRectInImage: CGRect) -> Void)?

    /// Called when editing chrome grows (e.g. new-person card) and may need a re-pin.
    var onEditingChromeNeedsRefocus: (() -> Void)?

    private var chromeByFaceId: [Int: PhotoFaceChromeView] = [:]
    private var faces: [PhotoFaceAnnotation] = []
    private var zoomScale: CGFloat = 1
    private var lastLaidOutSize: CGSize = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = true
        backgroundColor = .clear
        clipsToBounds = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// While a face is being edited, only that chrome (and empty space) receives hits —
    /// prevents z-order / overlapping chrome from stealing typeahead taps.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let editing = chromeByFaceId.values.filter(\.isActivelyEditing)
        if let editing = editing.first {
            let local = convert(point, to: editing)
            if let hit = editing.hitTest(local, with: event) {
                return hit
            }
            // Don't fall through to other face chrome while editing.
            return self
        }
        return super.hitTest(point, with: event)
    }

    func setFaces(_ faces: [PhotoFaceAnnotation]) {
        self.faces = faces
        let ids = Set(faces.map(\.faceInstanceId))
        for (id, view) in chromeByFaceId where !ids.contains(id) {
            view.removeFromSuperview()
            chromeByFaceId.removeValue(forKey: id)
        }

        for face in faces {
            let chrome: PhotoFaceChromeView
            if let existing = chromeByFaceId[face.faceInstanceId] {
                chrome = existing
            } else {
                chrome = PhotoFaceChromeView()
                chromeByFaceId[face.faceInstanceId] = chrome
                addSubview(chrome)
            }
            chrome.onBeginEditing = { [weak self] faceId, faceRect in
                guard let self else { return }
                self.endEditingExcept(faceId: faceId)
                if let chrome = self.chromeByFaceId[faceId] {
                    self.bringSubviewToFront(chrome)
                }
                self.onBeginEditingFace?(faceId, faceRect)
            }
            chrome.onAssign = { [weak self] faceId, display, first, last, maiden in
                self?.onAssign?(faceId, display, first, last, maiden)
                self?.endEditingExcept(faceId: nil)
            }
            chrome.onChromeNeedsRefocus = { [weak self] in
                self?.onEditingChromeNeedsRefocus?()
            }
            chrome.updateFace(face)
        }
        layoutChromeIfNeeded(force: true)
    }

    func updateZoomScale(_ scale: CGFloat) {
        let clamped = max(scale, 0.01)
        guard abs(clamped - zoomScale) > 0.000_1 else { return }
        zoomScale = clamped
        layoutChromeIfNeeded(force: true)
    }

    func endAllEditing() {
        endEditingExcept(faceId: nil)
    }

    /// Visible name-field rect in `target`'s coordinate space for a specific editing face.
    func activeNameFieldRect(for faceInstanceId: Int, in target: UIView) -> CGRect? {
        guard let chrome = chromeByFaceId[faceInstanceId], chrome.isActivelyEditing else {
            return nil
        }
        return chrome.nameFieldRect(in: target)
    }

    /// Name-field rect in window coordinates for the editing face (avoids scroll-view content/bounds mixups).
    func activeNameFieldWindowRect(for faceInstanceId: Int) -> CGRect? {
        guard let chrome = chromeByFaceId[faceInstanceId], chrome.isActivelyEditing else {
            return nil
        }
        return chrome.nameFieldWindowRect()
    }

    /// Union of name field + suggestions + new-person card in window coordinates.
    func activeEditingChromeWindowRect(for faceInstanceId: Int) -> CGRect? {
        guard let chrome = chromeByFaceId[faceInstanceId], chrome.isActivelyEditing else {
            return nil
        }
        return chrome.editingChromeWindowRect()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Only re-layout when our bounds change — never from chrome.frame updates mid-typing.
        guard bounds.size != lastLaidOutSize else { return }
        layoutChromeIfNeeded(force: true)
    }

    private func endEditingExcept(faceId: Int?) {
        for (id, chrome) in chromeByFaceId where id != faceId {
            chrome.cancelEditing()
        }
    }

    private func layoutChromeIfNeeded(force: Bool) {
        lastLaidOutSize = bounds.size
        for face in faces {
            guard let chrome = chromeByFaceId[face.faceInstanceId] else { continue }
            chrome.layout(face: face, inImageSize: bounds.size, zoomScale: zoomScale)
        }
        if force {
            // Keep editing chrome on top.
            for chrome in chromeByFaceId.values where chrome.isActivelyEditing {
                bringSubviewToFront(chrome)
            }
        }
    }
}

// MARK: - Per-face chrome

private final class PhotoFaceChromeView: UIView, UITextFieldDelegate {
    var onBeginEditing: ((_ faceInstanceId: Int, _ faceRectInImage: CGRect) -> Void)?
    var onAssign: ((
        _ faceInstanceId: Int,
        _ displayName: String,
        _ firstName: String?,
        _ lastName: String?,
        _ maidenName: String?
    ) -> Void)?
    var onChromeNeedsRefocus: (() -> Void)?

    private var face: PhotoFaceAnnotation?
    private var lastFaceRectInImage: CGRect = .zero
    private var currentZoomScale: CGFloat = 1
    private var isEditingName = false
    private var showingNewPersonCard = false
    private var knownPeople: [PeopleRepository.PersonRecord] = []
    private var matches: [PeopleRepository.PersonRecord] = []
    private var isUpdatingSuggestions = false

    private let boxView = ExpandedHitView()
    private let nameButton = ExpandedHitButton(type: .system)
    private let nameField = UITextField()
    private let suggestionsPanel = UIView()
    private let suggestionsStack = UIStackView()
    private let newPersonCard = NewPersonCardView()

    var isActivelyEditing: Bool { isEditingName }

    /// Face box in host/image coordinates (not chrome-local).
    var faceRectInHost: CGRect {
        lastFaceRectInImage
    }

    func nameFieldRect(in target: UIView) -> CGRect? {
        guard isEditingName, !nameField.isHidden else { return nil }
        return nameField.convert(nameField.bounds, to: target)
    }

    func nameFieldWindowRect() -> CGRect? {
        guard isEditingName, !nameField.isHidden, nameField.window != nil else { return nil }
        return nameField.convert(nameField.bounds, to: nil)
    }

    func editingChromeWindowRect() -> CGRect? {
        guard isEditingName, window != nil else { return nil }
        var unionRect: CGRect?
        func include(_ view: UIView) {
            guard !view.isHidden else { return }
            let rect = view.convert(view.bounds, to: nil)
            unionRect = unionRect.map { $0.union(rect) } ?? rect
        }
        include(nameField)
        include(suggestionsPanel)
        include(newPersonCard)
        return unionRect
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = false
        isUserInteractionEnabled = true

        boxView.backgroundColor = .clear
        boxView.layer.borderColor = UIColor.systemYellow.cgColor
        boxView.layer.borderWidth = 1
        boxView.isUserInteractionEnabled = true
        addSubview(boxView)

        nameButton.addTarget(self, action: #selector(nameChipTapped), for: .touchUpInside)
        let longPress = UILongPressGestureRecognizer(
            target: self,
            action: #selector(nameChipLongPressed(_:))
        )
        longPress.minimumPressDuration = 0.35
        nameButton.addGestureRecognizer(longPress)
        addSubview(nameButton)

        nameField.borderStyle = .none
        nameField.backgroundColor = .white
        nameField.textColor = .black
        nameField.font = .systemFont(ofSize: 11, weight: .semibold)
        nameField.layer.cornerRadius = 16
        nameField.clipsToBounds = true
        nameField.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 8, height: 1))
        nameField.leftViewMode = .always
        nameField.rightView = UIView(frame: CGRect(x: 0, y: 0, width: 8, height: 1))
        nameField.rightViewMode = .always
        nameField.returnKeyType = .done
        nameField.autocorrectionType = .no
        nameField.autocapitalizationType = .words
        nameField.delegate = self
        nameField.addTarget(self, action: #selector(nameFieldChanged), for: .editingChanged)
        nameField.isHidden = true
        addSubview(nameField)

        suggestionsPanel.backgroundColor = UIColor.black.withAlphaComponent(0.88)
        suggestionsPanel.layer.cornerRadius = 10
        suggestionsPanel.clipsToBounds = true
        suggestionsPanel.isHidden = true
        addSubview(suggestionsPanel)

        suggestionsStack.axis = .vertical
        suggestionsStack.spacing = 0
        suggestionsStack.translatesAutoresizingMaskIntoConstraints = false
        suggestionsPanel.addSubview(suggestionsStack)
        NSLayoutConstraint.activate([
            suggestionsStack.topAnchor.constraint(equalTo: suggestionsPanel.topAnchor, constant: 6),
            suggestionsStack.leadingAnchor.constraint(equalTo: suggestionsPanel.leadingAnchor),
            suggestionsStack.trailingAnchor.constraint(equalTo: suggestionsPanel.trailingAnchor),
            suggestionsStack.bottomAnchor.constraint(equalTo: suggestionsPanel.bottomAnchor, constant: -6),
        ])

        newPersonCard.isHidden = true
        newPersonCard.onSave = { [weak self] display, first, last, maiden in
            guard let self, let face = self.face else { return }
            self.onAssign?(face.faceInstanceId, display, first, last, maiden)
            self.cancelEditing()
        }
        newPersonCard.onCancel = { [weak self] in
            self?.showingNewPersonCard = false
            self?.newPersonCard.isHidden = true
            self?.applyLayoutPreservingField()
            self?.nameField.becomeFirstResponder()
        }
        addSubview(newPersonCard)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func updateFace(_ face: PhotoFaceAnnotation) {
        self.face = face
        if !isEditingName {
            var config = nameButton.configuration ?? .filled()
            config.title = face.idleNameChipTitle
            nameButton.configuration = config
        }
    }

    func cancelEditing() {
        isEditingName = false
        showingNewPersonCard = false
        nameField.resignFirstResponder()
        nameField.isHidden = true
        nameButton.isHidden = false
        suggestionsPanel.isHidden = true
        newPersonCard.isHidden = true
        applyLayoutPreservingField()
    }

    func layout(face: PhotoFaceAnnotation, inImageSize imageSize: CGSize, zoomScale: CGFloat) {
        self.face = face
        currentZoomScale = max(zoomScale, 0.01)
        updateFace(face)
        applyLayoutPreservingField()
    }

    /// Full geometry update. Safe during typing because it does not resign first responder
    /// and avoids host layoutSubviews feedback (host ignores frame-only changes).
    private func applyLayoutPreservingField() {
        guard let face, let imageSize = superview?.bounds.size, imageSize.width > 0 else { return }
        let inv = 1 / currentZoomScale
        let faceRect = Self.uiKitRect(for: face, in: imageSize)
        lastFaceRectInImage = faceRect

        // Screen-constant metrics expressed in image points.
        let nameH: CGFloat = 24 * inv
        let nameMinW: CGFloat = 52 * inv
        let gap: CGFloat = 4 * inv
        let listW: CGFloat = 280 * inv
        let rowH: CGFloat = 48 * inv
        let listPad: CGFloat = 6 * inv
        let cardW: CGFloat = 280 * inv
        // Title + Display/First/Last (compact) + buttons.
        let cardH: CGFloat = 200 * inv

        let nameFont = UIFont.systemFont(ofSize: 11 * inv, weight: .semibold)
        let suggestionFont = UIFont.systemFont(ofSize: 14 * inv, weight: .medium)
        let nameTitle = isEditingName
            ? (nameField.text?.isEmpty == false ? nameField.text! : "Name")
            : face.idleNameChipTitle
        let nameTextW = (nameTitle as NSString).size(withAttributes: [.font: nameFont]).width
        let nameW = max(nameMinW, nameTextW + 16 * inv)
        let fieldW = max(nameW, 120 * inv)

        let visibleMatches = Array(matches.prefix(6))
        let suggestionsListH: CGFloat = {
            guard isEditingName, !visibleMatches.isEmpty, !showingNewPersonCard else { return 0 }
            return listPad * 2 + CGFloat(visibleMatches.count) * rowH
        }()

        let circleSide = max(faceRect.width, faceRect.height)
        let showsCircle = !face.isNamed
        let markHeight = showsCircle ? circleSide : faceRect.height
        var contentHeight = markHeight + gap + nameH
        if suggestionsListH > 0 {
            contentHeight += gap + suggestionsListH
        }
        if showingNewPersonCard {
            contentHeight += gap + cardH
        }

        // Idle chrome stays tight to face + name so group shots don't steal taps with 280pt ghosts.
        let contentWidth: CGFloat
        if isEditingName {
            contentWidth = max(
                faceRect.width,
                fieldW,
                suggestionsListH > 0 ? listW : 0,
                showingNewPersonCard ? cardW : 0,
                showsCircle ? circleSide : 0
            )
        } else {
            contentWidth = max(faceRect.width, nameW, showsCircle ? circleSide : 0)
        }
        let circleOverflowY = showsCircle ? max(0, (circleSide - faceRect.height) / 2) : 0
        let originX = faceRect.midX - contentWidth / 2
        let originY = faceRect.minY - circleOverflowY
        frame = CGRect(x: originX, y: originY, width: contentWidth, height: contentHeight)

        let localFace = CGRect(
            x: faceRect.minX - originX,
            y: faceRect.minY - originY,
            width: faceRect.width,
            height: faceRect.height
        )
        let circleFrame = CGRect(
            x: localFace.midX - circleSide / 2,
            y: localFace.midY - circleSide / 2,
            width: circleSide,
            height: circleSide
        )
        boxView.frame = circleFrame
        boxView.layer.cornerRadius = circleSide / 2
        boxView.layer.borderWidth = 1 * inv
        boxView.isHidden = !showsCircle
        // Expand hit area to ~44pt on screen without changing the drawn circle.
        let minHit = 44 * inv
        boxView.hitOutset = max(0, (minHit - circleSide) * 0.5)

        let nameY = (showsCircle ? circleFrame.maxY : localFace.maxY) + gap
        let capsuleRadius = nameH / 2

        nameButton.frame = CGRect(
            x: (contentWidth - nameW) / 2,
            y: nameY,
            width: nameW,
            height: nameH
        )
        nameButton.hitOutset = max(0, (minHit - nameH) * 0.5)
        var nameConfig = UIButton.Configuration.filled()
        nameConfig.baseBackgroundColor = .white
        nameConfig.baseForegroundColor = .black
        nameConfig.cornerStyle = .capsule
        nameConfig.contentInsets = NSDirectionalEdgeInsets(
            top: 2 * inv, leading: 8 * inv, bottom: 2 * inv, trailing: 8 * inv
        )
        nameConfig.title = face.idleNameChipTitle
        nameConfig.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var out = incoming
            out.font = nameFont
            return out
        }
        nameButton.configuration = nameConfig

        nameField.frame = CGRect(
            x: (contentWidth - fieldW) / 2,
            y: nameY,
            width: fieldW,
            height: nameH
        )
        nameField.font = nameFont
        nameField.layer.cornerRadius = capsuleRadius
        if let left = nameField.leftView {
            left.frame = CGRect(x: 0, y: 0, width: 8 * inv, height: nameH)
        }
        if let right = nameField.rightView {
            right.frame = CGRect(x: 0, y: 0, width: 8 * inv, height: nameH)
        }

        var belowY = nameY + nameH
        if suggestionsListH > 0 {
            rebuildSuggestionsIfNeeded(matches: visibleMatches, font: suggestionFont, rowH: rowH, inv: inv)
            suggestionsPanel.isHidden = false
            suggestionsPanel.frame = CGRect(
                x: (contentWidth - listW) / 2,
                y: belowY + gap,
                width: listW,
                height: suggestionsListH
            )
            suggestionsPanel.layer.cornerRadius = 10 * inv
            belowY = suggestionsPanel.frame.maxY
        } else {
            suggestionsPanel.isHidden = true
            isUpdatingSuggestions = false
        }

        if showingNewPersonCard {
            newPersonCard.isHidden = false
            newPersonCard.frame = CGRect(
                x: (contentWidth - cardW) / 2,
                y: belowY + gap,
                width: cardW,
                height: cardH
            )
            newPersonCard.applyScale(inv)
        } else {
            newPersonCard.isHidden = true
        }

        nameButton.isHidden = isEditingName
        nameField.isHidden = !isEditingName
    }

    private func rebuildSuggestionsIfNeeded(
        matches: [PeopleRepository.PersonRecord],
        font: UIFont,
        rowH: CGFloat,
        inv: CGFloat
    ) {
        if isUpdatingSuggestions { return }
        isUpdatingSuggestions = true
        suggestionsStack.arrangedSubviews.forEach {
            suggestionsStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        for (index, person) in matches.enumerated() {
            let button = UIButton(type: .system)
            button.contentHorizontalAlignment = .leading
            button.contentEdgeInsets = UIEdgeInsets(
                top: 0, left: 12 * inv, bottom: 0, right: 12 * inv
            )
            button.setTitle(Self.suggestionTitle(for: person), for: .normal)
            button.setTitleColor(.white, for: .normal)
            button.titleLabel?.font = font
            button.titleLabel?.lineBreakMode = .byTruncatingTail
            button.tag = index
            button.heightAnchor.constraint(equalToConstant: rowH).isActive = true
            button.addTarget(self, action: #selector(suggestionTapped(_:)), for: .touchUpInside)
            suggestionsStack.addArrangedSubview(button)
        }
        isUpdatingSuggestions = false
    }

    @objc private func suggestionTapped(_ sender: UIButton) {
        guard let face, matches.indices.contains(sender.tag) else { return }
        let person = matches[sender.tag]
        onAssign?(
            face.faceInstanceId,
            person.displayName,
            person.firstName,
            person.lastName,
            person.maidenName
        )
        cancelEditing()
    }

    /// Tap: confirm high-confidence `Rick?`, otherwise open the name field.
    @objc private func nameChipTapped() {
        guard let face else { return }
        if face.hasConfidentNameSuggestion,
           let display = face.suggestedDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !display.isEmpty {
            onAssign?(
                face.faceInstanceId,
                display,
                face.suggestedFirstName,
                face.suggestedLastName,
                face.suggestedMaidenName
            )
            return
        }
        beginEditingName()
    }

    /// Long-press: always open typing so a wrong `Rick?` can be overridden.
    @objc private func nameChipLongPressed(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        beginEditingName()
    }

    private func beginEditingName() {
        guard let face else { return }
        let faceRect = lastFaceRectInImage.width > 0
            ? lastFaceRectInImage
            : Self.uiKitRect(for: face, in: superview?.bounds.size ?? .zero)

        // Show the name field first so zoom/pan can pin its live frame (not an estimate).
        isEditingName = true
        showingNewPersonCard = false
        newPersonCard.isHidden = true
        knownPeople = AppDependencies.database.fetchAllPeople()
        // Seed visual suggestion first so override still shows Rick at the top of the list.
        if face.hasConfidentNameSuggestion,
           let suggestedId = face.suggestedPersonId,
           let suggested = knownPeople.first(where: { $0.personId == suggestedId }) {
            matches = [suggested]
        } else {
            matches = []
        }
        nameButton.isHidden = true
        nameField.isHidden = false
        nameField.text = face.isNamed ? (face.personDisplayName ?? "") : ""
        nameField.placeholder = "Name"
        applyLayoutPreservingField()

        onBeginEditing?(face.faceInstanceId, faceRect)
        DispatchQueue.main.async { [weak self] in
            self?.nameField.becomeFirstResponder()
        }
    }

    @objc private func nameFieldChanged() {
        let query = (nameField.text ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let newMatches: [PeopleRepository.PersonRecord]
        if query.isEmpty {
            // Keep visual suggestion visible while the field is empty (long-press override).
            if let face,
               face.hasConfidentNameSuggestion,
               let suggestedId = face.suggestedPersonId,
               let suggested = knownPeople.first(where: { $0.personId == suggestedId }) {
                newMatches = [suggested]
            } else {
                newMatches = []
            }
        } else {
            var filtered = knownPeople
                .filter { $0.displayName.localizedCaseInsensitiveContains(query) }
            if let face,
               face.hasConfidentNameSuggestion,
               let suggestedId = face.suggestedPersonId,
               let suggested = knownPeople.first(where: { $0.personId == suggestedId }),
               filtered.contains(where: { $0.personId == suggestedId }) {
                filtered.removeAll { $0.personId == suggestedId }
                filtered.insert(suggested, at: 0)
            }
            newMatches = Array(filtered.prefix(8))
        }
        // Avoid work if matches unchanged (same ids).
        let oldIds = matches.map(\.personId)
        let newIds = newMatches.map(\.personId)
        matches = newMatches
        guard oldIds != newIds else {
            // Still widen the field for longer typed text without rebuilding suggestions.
            applyLayoutPreservingField()
            return
        }
        isUpdatingSuggestions = false
        applyLayoutPreservingField()
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        let draft = (textField.text ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !draft.isEmpty, let face else { return false }

        if let exact = knownPeople.first(where: {
            $0.displayName.compare(draft, options: .caseInsensitive) == .orderedSame
        }) {
            onAssign?(
                face.faceInstanceId,
                exact.displayName,
                exact.firstName,
                exact.lastName,
                exact.maidenName
            )
            cancelEditing()
            return true
        }

        showingNewPersonCard = true
        suggestionsPanel.isHidden = true
        let parts = draft.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        let first = parts.first.map(String.init)
        let last = parts.count > 1 ? String(parts[1]) : nil
        newPersonCard.populate(displayName: draft, firstName: first, lastName: last)
        textField.resignFirstResponder()
        applyLayoutPreservingField()
        onChromeNeedsRefocus?()
        return true
    }

    private static func suggestionTitle(for person: PeopleRepository.PersonRecord) -> String {
        let first = person.firstName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let last = person.lastName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let full = [first, last].filter { !$0.isEmpty }.joined(separator: " ")
        if full.isEmpty { return person.displayName }
        return "\(person.displayName) (\(full))"
    }

    private static func uiKitRect(for face: PhotoFaceAnnotation, in imageSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let box = face.faceBoundingBox
        let width = max(box.width * imageSize.width, 1)
        let height = max(box.height * imageSize.height, 1)
        let x = box.origin.x * imageSize.width
        let y = (1 - box.origin.y - box.height) * imageSize.height
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

// MARK: - Compact new person card

private final class NewPersonCardView: UIView {
    var onSave: ((_ displayName: String, _ firstName: String?, _ lastName: String?, _ maidenName: String?) -> Void)?
    var onCancel: (() -> Void)?

    private let titleLabel = UILabel()
    private let displayRow = LabeledFieldRow(labelText: "Display name")
    private let firstRow = LabeledFieldRow(labelText: "First name")
    private let lastRow = LabeledFieldRow(labelText: "Last name")
    private let saveButton = UIButton(type: .system)
    private let cancelButton = UIButton(type: .system)
    private let stack = UIStackView()
    private let buttons = UIStackView()
    private var stackTop: NSLayoutConstraint?
    private var stackLeading: NSLayoutConstraint?
    private var stackTrailing: NSLayoutConstraint?
    private var buttonsTop: NSLayoutConstraint?
    private var buttonsLeading: NSLayoutConstraint?
    private var buttonsTrailing: NSLayoutConstraint?
    private var buttonsBottom: NSLayoutConstraint?
    private var fieldHeightConstraints: [NSLayoutConstraint] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(white: 0.28, alpha: 0.95)
        clipsToBounds = true

        titleLabel.text = "New person"
        titleLabel.textColor = .white

        saveButton.setTitle("Save", for: .normal)
        saveButton.addTarget(self, action: #selector(saveTapped), for: .touchUpInside)

        cancelButton.setTitle("Cancel", for: .normal)
        cancelButton.tintColor = .lightGray
        cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)

        stack.axis = .vertical
        stack.translatesAutoresizingMaskIntoConstraints = false
        [titleLabel, displayRow, firstRow, lastRow].forEach(stack.addArrangedSubview)
        addSubview(stack)

        buttons.axis = .horizontal
        buttons.distribution = .fillEqually
        buttons.translatesAutoresizingMaskIntoConstraints = false
        buttons.addArrangedSubview(cancelButton)
        buttons.addArrangedSubview(saveButton)
        addSubview(buttons)

        stackTop = stack.topAnchor.constraint(equalTo: topAnchor, constant: 10)
        stackLeading = stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10)
        stackTrailing = stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10)
        buttonsTop = buttons.topAnchor.constraint(equalTo: stack.bottomAnchor, constant: 8)
        buttonsLeading = buttons.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10)
        buttonsTrailing = buttons.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10)
        buttonsBottom = buttons.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10)
        NSLayoutConstraint.activate([
            stackTop!, stackLeading!, stackTrailing!,
            buttonsTop!, buttonsLeading!, buttonsTrailing!, buttonsBottom!,
        ])

        applyScale(1)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// `inv = 1/zoomScale` so fonts/padding stay constant on screen while the card is in image space.
    func applyScale(_ inv: CGFloat) {
        let pad = 10 * inv
        let spacing = 6 * inv
        let fieldH = 28 * inv
        layer.cornerRadius = 12 * inv
        titleLabel.font = .systemFont(ofSize: 13 * inv, weight: .semibold)
        displayRow.applyScale(inv)
        firstRow.applyScale(inv)
        lastRow.applyScale(inv)
        saveButton.titleLabel?.font = .systemFont(ofSize: 14 * inv, weight: .semibold)
        cancelButton.titleLabel?.font = .systemFont(ofSize: 14 * inv, weight: .regular)
        stack.spacing = spacing
        buttons.spacing = 10 * inv
        stackTop?.constant = pad
        stackLeading?.constant = pad
        stackTrailing?.constant = -pad
        buttonsTop?.constant = 8 * inv
        buttonsLeading?.constant = pad
        buttonsTrailing?.constant = -pad
        buttonsBottom?.constant = -pad

        fieldHeightConstraints.forEach { $0.isActive = false }
        fieldHeightConstraints = [
            displayRow.heightAnchor.constraint(equalToConstant: fieldH),
            firstRow.heightAnchor.constraint(equalToConstant: fieldH),
            lastRow.heightAnchor.constraint(equalToConstant: fieldH),
        ]
        NSLayoutConstraint.activate(fieldHeightConstraints)
    }

    func populate(displayName: String, firstName: String?, lastName: String?) {
        displayRow.field.text = displayName
        firstRow.field.text = firstName
        lastRow.field.text = lastName
    }

    @objc private func saveTapped() {
        let display = (displayRow.field.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !display.isEmpty else { return }
        onSave?(
            display,
            trimmedOptional(firstRow.field.text),
            trimmedOptional(lastRow.field.text),
            nil
        )
    }

    @objc private func cancelTapped() {
        onCancel?()
    }

    private func trimmedOptional(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Label on the left, compact white text field on the right.
private final class LabeledFieldRow: UIView {
    let field = UITextField()
    private let label = UILabel()
    private var labelWidth: NSLayoutConstraint?

    init(labelText: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        label.text = labelText
        label.textColor = UIColor.white.withAlphaComponent(0.85)
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false

        field.borderStyle = .none
        field.backgroundColor = .white
        field.textColor = .black
        field.autocorrectionType = .no
        field.autocapitalizationType = .words
        field.clipsToBounds = true
        field.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 8, height: 1))
        field.leftViewMode = .always
        field.rightView = UIView(frame: CGRect(x: 0, y: 0, width: 8, height: 1))
        field.rightViewMode = .always
        field.translatesAutoresizingMaskIntoConstraints = false

        addSubview(label)
        addSubview(field)
        labelWidth = label.widthAnchor.constraint(equalToConstant: 88)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            labelWidth!,
            field.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 8),
            field.trailingAnchor.constraint(equalTo: trailingAnchor),
            field.topAnchor.constraint(equalTo: topAnchor),
            field.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func applyScale(_ inv: CGFloat) {
        label.font = .systemFont(ofSize: 11 * inv, weight: .medium)
        field.font = .systemFont(ofSize: 13 * inv)
        field.layer.cornerRadius = 6 * inv
        labelWidth?.constant = 88 * inv
        if let left = field.leftView {
            left.bounds.size = CGSize(width: 8 * inv, height: 1)
        }
        if let right = field.rightView {
            right.bounds.size = CGSize(width: 8 * inv, height: 1)
        }
    }
}

// MARK: - Expanded hit targets

private final class ExpandedHitView: UIView {
    var hitOutset: CGFloat = 0

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: -hitOutset, dy: -hitOutset).contains(point)
    }
}

private final class ExpandedHitButton: UIButton {
    var hitOutset: CGFloat = 0

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: -hitOutset, dy: -hitOutset).contains(point)
    }
}
