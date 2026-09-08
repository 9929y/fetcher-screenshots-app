import Foundation

/// The other half of the output.
///
/// The three target tools are all code-generation tools, so the text is not a
/// caption — it is the instruction set, and it needs the numbered items to map
/// one-to-one onto the badges in the image.
enum PromptGenerator {

    /// `{{items}}` is the only required token. Kept as a template because the
    /// preamble is exactly the kind of thing a user wants to phrase their own
    /// way, and hard-coding it would guarantee they edit every paste by hand.
    static let defaultTemplate = """
    Apply these changes to the attached screenshot.
    Each numbered item refers to the same-numbered box in the image.

    {{items}}

    Change only what's listed. Leave everything else as-is.
    """

    static func text(for annotations: [Annotation],
                     template: String? = nil) -> String {
        let template = template ?? Settings.shared.promptTemplate

        let listed = annotations.enumerated().compactMap { i, a -> (Int, Annotation)? in
            a.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : (i + 1, a)
        }
        guard !listed.isEmpty else { return "" }

        // The color word is a redundancy: the user says "the teal one" out loud
        // and it gives the model a second way to bind text to box. But once the
        // palette is customizable, two slots can land in the same hue family —
        // and "(blue)" appearing twice reintroduces exactly the ambiguity the
        // numbers exist to remove. So it is kept where it is unique and dropped
        // where it is not, per name rather than all-or-nothing.
        var occurrences: [String: Int] = [:]
        for (_, a) in listed {
            occurrences[Palette.name(a.wheelIndex), default: 0] += 1
        }

        let items = listed.map { number, a -> String in
            let name = Palette.name(a.wheelIndex)
            let colour = occurrences[name] == 1 ? " (\(name))" : ""
            return "\(number).\(colour) \(collapse(a.note))"
        }
        return template.replacingOccurrences(of: "{{items}}",
                                             with: items.joined(separator: "\n"))
    }

    /// Notes may contain newlines from shift-return. In the numbered list they
    /// become a single flowing item so the list structure survives.
    private static func collapse(_ note: String) -> String {
        note.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
