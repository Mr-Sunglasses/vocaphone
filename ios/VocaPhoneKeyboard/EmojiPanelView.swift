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
    private let feedback: any KeyboardFeedbackProviding

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

    init(
        palette: KeyboardPalette,
        metrics: KeyboardMetrics,
        feedback: any KeyboardFeedbackProviding = KeyboardHaptics.shared
    ) {
        self.palette = palette
        self.metrics = metrics
        self.feedback = feedback
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
            button.addTarget(self, action: #selector(keyPressed), for: .touchDown)
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
        button.addTarget(self, action: #selector(keyPressed), for: .touchDown)
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

    /// The panel's controls are `UIButton`s and collection cells rather than the
    /// grid's own hit-tested keys, so the click has to be hung off touch-down
    /// explicitly. Without it the panel would sound a beat later than the
    /// keyboard the user just came from.
    @objc private func keyPressed() {
        feedback.keyPressed()
    }

    @objc private func searchChanged() {
        query = searchField.text ?? ""
        reload()
    }

    @objc private func categoryTapped(_ sender: UIButton) {
        guard sender.tag < EmojiCategory.allCases.count else { return }
        feedback.selectionChanged()
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
        feedback.selectionChanged()
        delegate?.emojiPanelDidRequestLetters(self)
    }

    @objc private func spaceTapped() {
        feedback.textCommitted()
        delegate?.emojiPanelDidRequestSpace(self)
    }

    @objc private func deleteTapped() {
        feedback.keyActionCommitted()
        delegate?.emojiPanelDidRequestDelete(self)
    }

    @objc private func returnTapped() {
        feedback.textCommitted()
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

    func collectionView(_ collectionView: UICollectionView, didHighlightItemAt indexPath: IndexPath) {
        // Highlight is the cell's touch-down, which is where a key clicks.
        feedback.keyPressed()
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard indexPath.item < glyphs.count else { return }
        let glyph = glyphs[indexPath.item]
        feedback.textCommitted()
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

#if DEBUG
import SwiftUI

// MARK: - Previews

// The panel occupies exactly the key grid's space, so it is previewed at the
// grid's resolved height for each of the three keyboard heights. What matters
// here is that ABC, space, delete and return stay pinned at the bottom: this is
// the surface a user can otherwise get stuck in.

/// `EmojiCatalog` builds only in the keyboard and the test target, so the
/// fixture lives beside the view that needs it rather than in the shared
/// preview helpers, which the app target also compiles.
private enum EmojiPanelFixture {
    /// Small enough to write down, large enough that the grid, the category bar
    /// and search all have something to draw.
    static let emojiCatalog = EmojiCatalog(entries: [
        EmojiEntry(glyph: "😀", category: .smileys, keywords: "grinning face smile happy"),
        EmojiEntry(glyph: "😅", category: .smileys, keywords: "grinning sweat relief nervous"),
        EmojiEntry(glyph: "🙂", category: .smileys, keywords: "slightly smiling face"),
        EmojiEntry(glyph: "😍", category: .smileys, keywords: "heart eyes love"),
        EmojiEntry(glyph: "🤔", category: .smileys, keywords: "thinking face hmm"),
        EmojiEntry(glyph: "😴", category: .smileys, keywords: "sleeping face tired"),
        EmojiEntry(glyph: "👋", category: .people, keywords: "waving hand hello goodbye"),
        EmojiEntry(glyph: "👍", category: .people, keywords: "thumbs up yes approve"),
        EmojiEntry(glyph: "🙏", category: .people, keywords: "folded hands please thanks"),
        EmojiEntry(glyph: "🐻", category: .animals, keywords: "bear face"),
        EmojiEntry(glyph: "🐈", category: .animals, keywords: "cat pet"),
        EmojiEntry(glyph: "🌱", category: .animals, keywords: "seedling plant grow"),
        EmojiEntry(glyph: "🍔", category: .food, keywords: "hamburger burger food"),
        EmojiEntry(glyph: "☕", category: .food, keywords: "hot beverage coffee tea"),
        EmojiEntry(glyph: "✈️", category: .travel, keywords: "airplane flight travel"),
        EmojiEntry(glyph: "🚲", category: .travel, keywords: "bicycle bike ride"),
        EmojiEntry(glyph: "⚽", category: .activities, keywords: "soccer ball football"),
        EmojiEntry(glyph: "🎧", category: .activities, keywords: "headphone music listen"),
        EmojiEntry(glyph: "💡", category: .objects, keywords: "light bulb idea"),
        EmojiEntry(glyph: "🔑", category: .objects, keywords: "key unlock"),
        EmojiEntry(glyph: "❤️", category: .symbols, keywords: "red heart love"),
        EmojiEntry(glyph: "✅", category: .symbols, keywords: "check mark done"),
        EmojiEntry(glyph: "🚩", category: .flags, keywords: "triangular flag"),
    ])
}

private struct EmojiPanelPreview: View {
    var preference: KeyboardHeightPreference = .standard
    var dark = false
    var catalog: EmojiCatalog = EmojiPanelFixture.emojiCatalog

    var body: some View {
        let metrics = KeyboardPreviewEnvironment.gridMetrics(preference)
        let palette = KeyboardPreviewEnvironment.palette(dark: dark)
        return KeyboardViewPreview {
            EmojiPanelView(palette: palette, metrics: metrics)
        } configure: { panel in
            panel.palette = palette
            panel.metrics = metrics
            panel.catalog = catalog
        }
        .frame(width: 360, height: metrics.gridHeight)
        .background(Color(palette.background))
    }
}

#Preview("Emoji panel — standard", traits: .sizeThatFitsLayout) {
    EmojiPanelPreview().padding()
}

#Preview("Emoji panel — dark", traits: .sizeThatFitsLayout) {
    EmojiPanelPreview(dark: true).padding()
}

#Preview("Emoji panel — every height", traits: .sizeThatFitsLayout) {
    HStack(alignment: .top, spacing: 16) {
        ForEach(KeyboardHeightPreference.allCases) { preference in
            VStack(spacing: 6) {
                Text(preference.displayName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                EmojiPanelPreview(preference: preference)
            }
        }
    }
    .padding()
}

/// A catalog that failed to load is a real state — the shared TSV lives in a
/// resource bundle the extension has to find — and it must not read as a broken
/// keyboard.
#Preview("Emoji panel — empty catalog", traits: .sizeThatFitsLayout) {
    EmojiPanelPreview(catalog: .empty).padding()
}
#endif
