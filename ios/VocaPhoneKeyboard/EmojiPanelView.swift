import UIKit

@MainActor
protocol EmojiPanelViewDelegate: AnyObject {
    func emojiPanel(_ panel: EmojiPanelView, didChoose glyph: String)
    func emojiPanelDidRequestDelete(_ panel: EmojiPanelView)
    func emojiPanelDidRequestReturn(_ panel: EmojiPanelView)
    func emojiPanelDidRequestSpace(_ panel: EmojiPanelView)
    func emojiPanelDidRequestLetters(_ panel: EmojiPanelView)
}

/// The emoji panel, occupying exactly the space the key grid occupies.
///
/// Using an emoji currently means switching keyboards, which on a third-party
/// keyboard also means losing the dictation bar — so the one thing this panel
/// must not do is cost height. It replaces the grid rather than joining it, and
/// `ABC`, space, delete and return stay pinned at the bottom so the keyboard
/// never becomes a place you can get stuck.
final class EmojiPanelView: UIView {
    weak var delegate: (any EmojiPanelViewDelegate)?

    var palette: KeyboardPalette {
        didSet {
            guard palette != oldValue else { return }
            applyPalette()
        }
    }

    var metrics: KeyboardMetrics {
        didSet {
            guard metrics != oldValue else { return }
            reload()
        }
    }

    var catalog: EmojiCatalog = .empty {
        didSet { reload() }
    }

    private var category: EmojiCategory = .smileys
    private var query = ""
    private var glyphs: [String] = []

    private let searchField = UITextField()
    private let categoryBar = UIScrollView()
    private let categoryRow = UIStackView()
    private var categoryButtons: [UIButton] = []
    private lazy var collection: UICollectionView = {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .vertical
        layout.minimumInteritemSpacing = 0
        layout.minimumLineSpacing = 2
        let view = UICollectionView(frame: .zero, collectionViewLayout: layout)
        view.backgroundColor = .clear
        view.register(EmojiCell.self, forCellWithReuseIdentifier: EmojiCell.identifier)
        view.dataSource = self
        view.delegate = self
        view.keyboardDismissMode = .none
        return view
    }()
    private let bottomRow = UIStackView()

    init(palette: KeyboardPalette, metrics: KeyboardMetrics) {
        self.palette = palette
        self.metrics = metrics
        super.init(frame: .zero)
        configure()
        applyPalette()
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Content

    private func reload() {
        glyphs = resolvedGlyphs()
        collection.reloadData()
        for (index, category) in EmojiCategory.allCases.enumerated()
        where index < categoryButtons.count {
            let isSelected = category == self.category && query.isEmpty
            categoryButtons[index].backgroundColor = isSelected
                ? palette.functionKey
                : .clear
            categoryButtons[index].accessibilityTraits = isSelected
                ? [.button, .selected]
                : .button
        }
        collection.collectionViewLayout.invalidateLayout()
    }

    private func resolvedGlyphs() -> [String] {
        guard query.isEmpty else { return catalog.search(query).map(\.glyph) }
        guard category != .recents else { return EmojiRecents.glyphs }
        return catalog.entries(in: category).map(\.glyph)
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        let searchHeight: CGFloat = 34
        let categoryHeight: CGFloat = 34
        let bottomHeight = metrics.keyHeight
        searchField.frame = CGRect(
            x: metrics.sideInset,
            y: 0,
            width: bounds.width - 2 * metrics.sideInset,
            height: searchHeight
        )
        categoryBar.frame = CGRect(
            x: 0,
            y: searchHeight + 2,
            width: bounds.width,
            height: categoryHeight
        )
        let collectionTop = categoryBar.frame.maxY + 2
        collection.frame = CGRect(
            x: metrics.sideInset,
            y: collectionTop,
            width: bounds.width - 2 * metrics.sideInset,
            height: max(0, bounds.height - collectionTop - bottomHeight - 4)
        )
        bottomRow.frame = CGRect(
            x: metrics.sideInset,
            y: bounds.height - bottomHeight,
            width: bounds.width - 2 * metrics.sideInset,
            height: bottomHeight
        )
    }

    /// A grid whose cells are square and roughly a fingertip wide. Derived from
    /// the width rather than fixed, so it fills a Max the same way it fills a
    /// small phone.
    fileprivate var itemSize: CGSize {
        let available = collection.bounds.width
        guard available > 0 else { return CGSize(width: 40, height: 40) }
        let columns = max(6, Int(available / 44))
        let side = available / CGFloat(columns)
        return CGSize(width: side, height: side)
    }

    // MARK: - Construction

    private func configure() {
        searchField.placeholder = "Search emoji"
        searchField.borderStyle = .none
        searchField.clearButtonMode = .whileEditing
        searchField.autocorrectionType = .no
        searchField.autocapitalizationType = .none
        searchField.returnKeyType = .search
        searchField.layer.cornerRadius = 8
        searchField.layer.cornerCurve = .continuous
        searchField.addTarget(self, action: #selector(searchChanged), for: .editingChanged)
        // A left inset, because a text field with text against its own edge
        // reads as broken.
        searchField.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 10, height: 1))
        searchField.leftViewMode = .always
        addSubview(searchField)

        categoryRow.axis = .horizontal
        categoryRow.spacing = 2
        categoryBar.showsHorizontalScrollIndicator = false
        categoryBar.addSubview(categoryRow)
        addSubview(categoryBar)

        for (index, category) in EmojiCategory.allCases.enumerated() {
            let button = UIButton(type: .system)
            button.tag = index
            button.setTitle(category.icon, for: .normal)
            button.titleLabel?.font = .systemFont(ofSize: 17)
            button.layer.cornerRadius = 8
            button.layer.cornerCurve = .continuous
            button.accessibilityLabel = category.label
            button.addTarget(self, action: #selector(categoryTapped), for: .touchUpInside)
            categoryRow.addArrangedSubview(button)
            button.widthAnchor.constraint(equalToConstant: 40).isActive = true
            categoryButtons.append(button)
        }

        addSubview(collection)

        bottomRow.axis = .horizontal
        bottomRow.spacing = metrics.columnGap
        bottomRow.distribution = .fill
        addSubview(bottomRow)
        buildBottomRow()
    }

    /// `ABC`, space, delete and return: the four things that must never be more
    /// than one tap away, whatever plane the keyboard is showing.
    private func buildBottomRow() {
        bottomRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let letters = bottomButton(title: "ABC", action: #selector(lettersTapped))
        let space = bottomButton(title: "space", action: #selector(spaceTapped))
        let delete = bottomButton(symbol: "delete.left", action: #selector(deleteTapped))
        let newline = bottomButton(symbol: "return", action: #selector(returnTapped))
        [letters, space, delete, newline].forEach(bottomRow.addArrangedSubview)
        letters.widthAnchor.constraint(equalToConstant: 64).isActive = true
        delete.widthAnchor.constraint(equalToConstant: 52).isActive = true
        newline.widthAnchor.constraint(equalToConstant: 64).isActive = true
        letters.accessibilityLabel = "Letters"
        delete.accessibilityLabel = "Delete"
        newline.accessibilityLabel = "Return"
    }

    private func bottomButton(
        title: String? = nil,
        symbol: String? = nil,
        action: Selector
    ) -> UIButton {
        let button = UIButton(type: .system)
        if let title { button.setTitle(title, for: .normal) }
        if let symbol { button.setImage(UIImage(systemName: symbol), for: .normal) }
        button.titleLabel?.font = .systemFont(ofSize: metrics.functionFontSize, weight: .medium)
        button.layer.cornerRadius = metrics.cornerRadius
        button.layer.cornerCurve = .continuous
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }

    private func applyPalette() {
        backgroundColor = palette.background
        searchField.backgroundColor = palette.functionKey
        searchField.textColor = palette.keyForeground
        for button in bottomRow.arrangedSubviews.compactMap({ $0 as? UIButton }) {
            button.backgroundColor = palette.functionKey
            button.tintColor = palette.keyForeground
            button.setTitleColor(palette.keyForeground, for: .normal)
        }
        for button in categoryButtons { button.tintColor = palette.keyForeground }
        collection.reloadData()
    }

    // MARK: - Actions

    @objc private func searchChanged() {
        query = searchField.text ?? ""
        reload()
    }

    @objc private func categoryTapped(_ sender: UIButton) {
        guard sender.tag < EmojiCategory.allCases.count else { return }
        KeyboardHaptics.shared.selectionChanged()
        category = EmojiCategory.allCases[sender.tag]
        query = ""
        searchField.text = ""
        searchField.resignFirstResponder()
        reload()
        collection.setContentOffset(.zero, animated: false)
    }

    // The four pinned keys insert and delete exactly as the grid's own do, so
    // they tap back the same way. A panel that goes silent the moment it opens
    // reads as a keyboard that has stopped responding.
    @objc private func lettersTapped() {
        KeyboardHaptics.shared.selectionChanged()
        delegate?.emojiPanelDidRequestLetters(self)
    }

    @objc private func spaceTapped() {
        KeyboardHaptics.shared.keyPress()
        delegate?.emojiPanelDidRequestSpace(self)
    }

    @objc private func deleteTapped() {
        KeyboardHaptics.shared.keyPress()
        delegate?.emojiPanelDidRequestDelete(self)
    }

    @objc private func returnTapped() {
        KeyboardHaptics.shared.keyPress()
        delegate?.emojiPanelDidRequestReturn(self)
    }
}

extension EmojiPanelView: UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        glyphs.count
    }

    func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: EmojiCell.identifier,
            for: indexPath
        )
        (cell as? EmojiCell)?.show(glyphs[indexPath.item])
        return cell
    }

    func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> CGSize {
        itemSize
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard indexPath.item < glyphs.count else { return }
        let glyph = glyphs[indexPath.item]
        KeyboardHaptics.shared.keyPress()
        EmojiRecents.note(glyph)
        delegate?.emojiPanel(self, didChoose: glyph)
    }
}

final class EmojiCell: UICollectionViewCell {
    static let identifier = "EmojiCell"

    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.textAlignment = .center
        label.font = .systemFont(ofSize: 30)
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.6
        contentView.addSubview(label)
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = contentView.bounds
    }

    func show(_ glyph: String) {
        label.text = glyph
        accessibilityLabel = glyph
    }
}
