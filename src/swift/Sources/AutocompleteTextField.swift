import SwiftUI

// MARK: - Autocomplete TextField Component

/// A combo-box style text field that shows a dropdown of matching suggestions
/// as the user types. Supports case-insensitive filtering and allows free-form input.
struct AutocompleteTextField: View {
    let placeholder: String
    @Binding var text: String
    let suggestions: [String]

    @State private var isShowingDropdown = false
    @State private var isFocused = false
    @FocusState private var fieldFocused: Bool

    private var filteredSuggestions: [String] {
        guard !text.isEmpty else { return suggestions }
        return suggestions.filter {
            $0.localizedCaseInsensitiveContains(text) && $0.lowercased() != text.lowercased()
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($fieldFocused)
                .onChange(of: fieldFocused) { _, focused in
                    isFocused = focused
                    if focused {
                        isShowingDropdown = true
                    }
                }
                .onChange(of: text) { _, _ in
                    if isFocused {
                        isShowingDropdown = true
                    }
                }
                .onSubmit {
                    isShowingDropdown = false
                }

            if isShowingDropdown && isFocused && !filteredSuggestions.isEmpty {
                dropdownList
                    .zIndex(1)
            }
        }
        .onExitCommand {
            isShowingDropdown = false
            fieldFocused = false
        }
    }

    private var dropdownList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(filteredSuggestions.prefix(8), id: \.self) { suggestion in
                    Button(action: {
                        text = suggestion
                        isShowingDropdown = false
                        fieldFocused = false
                    }) {
                        Text(suggestion)
                            .font(.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(Color.clear)
                    .onHover { hovering in
                        // Hover effect handled by SwiftUI
                    }

                    if suggestion != filteredSuggestions.prefix(8).last {
                        Divider()
                    }
                }
            }
        }
        .frame(maxHeight: 200)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(6)
        .shadow(color: Color.black.opacity(0.2), radius: 4, x: 0, y: 2)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.gray.opacity(0.3), lineWidth: 1)
        )
    }
}
