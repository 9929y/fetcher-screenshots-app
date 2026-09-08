import Foundation
import CoreGraphics

/// A box and its note are one object. Color, badge, legend row and lifecycle
/// are all derived from this — there is nothing to keep in sync by hand, which
/// is the whole point.
///
/// `rect` is in **image pixel coordinates with a top-left origin**, the same
/// space as the captured `CGImage`. Keeping one coordinate space from capture
/// through editing to export removes an entire category of off-by-a-flip bug;
/// the editor view is `isFlipped` so its coordinates match too.
struct Annotation: Identifiable, Equatable {
    let id: UUID
    var rect: CGRect
    /// Index into `Palette.wheel`. Assigned automatically, overridable with 1–0.
    var wheelIndex: Int
    var note: String

    init(id: UUID = UUID(), rect: CGRect, wheelIndex: Int, note: String = "") {
        self.id = id
        self.rect = rect
        self.wheelIndex = wheelIndex
        self.note = note
    }
}

/// The markup on one capture.
///
/// Undo is snapshot-based rather than command-based. With at most a handful of
/// annotations a snapshot costs nothing, and it makes "undo restores exactly
/// what was there" true by construction instead of true if every inverse
/// operation was written correctly.
final class MarkupDocument {

    private(set) var annotations: [Annotation] = []
    private var undoStack: [[Annotation]] = []
    private var redoStack: [[Annotation]] = []

    var isEmpty: Bool { annotations.isEmpty }
    var count: Int { annotations.count }

    /// Display number for an annotation: its position, 1-based. Numbers stay
    /// contiguous because the generated prompt is an ordered list.
    func number(of id: Annotation.ID) -> Int? {
        annotations.firstIndex { $0.id == id }.map { $0 + 1 }
    }

    func annotation(_ id: Annotation.ID) -> Annotation? {
        annotations.first { $0.id == id }
    }

    /// The color the next box will get, so the editor can preview it.
    var nextWheelIndex: Int {
        Palette.wheelIndex(forAnnotation: annotations.count)
    }

    /// Replaces the contents wholesale, with no history behind it — reopening
    /// a finished capture is a fresh start, not a step you can undo past.
    func load(_ restored: [Annotation]) {
        annotations = restored
        undoStack.removeAll()
        redoStack.removeAll()
    }

    @discardableResult
    func add(rect: CGRect) -> Annotation {
        checkpoint()
        let a = Annotation(rect: rect, wheelIndex: nextWheelIndex)
        annotations.append(a)
        return a
    }

    func delete(_ id: Annotation.ID) {
        guard annotations.contains(where: { $0.id == id }) else { return }
        checkpoint()
        annotations.removeAll { $0.id == id }
    }

    /// Note edits coalesce: a checkpoint per keystroke would make undo useless.
    /// The editor calls `beginNoteEdit` once when the field opens.
    func beginNoteEdit(_ id: Annotation.ID) {
        guard annotations.contains(where: { $0.id == id }) else { return }
        checkpoint()
    }

    func setNote(_ note: String, for id: Annotation.ID) {
        guard let i = annotations.firstIndex(where: { $0.id == id }) else { return }
        annotations[i].note = note
    }

    /// A manual color override. Deleting a box renumbers the others but leaves
    /// their colors alone — the user picked the box out by color with their
    /// eyes, and reshuffling hues under them would invalidate notes they have
    /// already typed. Numbers renumber; colors are sticky.
    func setColor(wheelIndex: Int, for id: Annotation.ID) {
        guard let i = annotations.firstIndex(where: { $0.id == id }),
              annotations[i].wheelIndex != wheelIndex else { return }
        checkpoint()
        annotations[i].wheelIndex = wheelIndex
    }

    func setRect(_ rect: CGRect, for id: Annotation.ID, checkpointing: Bool) {
        guard let i = annotations.firstIndex(where: { $0.id == id }) else { return }
        if checkpointing { checkpoint() }
        annotations[i].rect = rect
    }

    /// Hit test, front-most first. Creation order is z-order.
    func hits(at point: CGPoint) -> [Annotation] {
        annotations.reversed().filter { $0.rect.insetBy(dx: -3, dy: -3).contains(point) }
    }

    // MARK: Undo

    private func checkpoint() {
        undoStack.append(annotations)
        redoStack.removeAll()
        if undoStack.count > 200 { undoStack.removeFirst() }
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(annotations)
        annotations = previous
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(annotations)
        annotations = next
    }
}
