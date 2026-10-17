import SwiftUI

/// Shown when a search finds nothing. SwiftUI's own version only speaks the languages macOS has, and Azerbaijani isn't
/// one of them.
struct NoSearchResults: View {
    let text: String

    var body: some View {
        ContentUnavailableView {
            Label {
                if text.isEmpty {
                    Text("No Results")
                } else {
                    Text("No Results for “\(text)”")
                }
            } icon: {
                Image(systemName: "magnifyingglass")
            }
        } description: {
            Text("Check the spelling or try a new search.")
        }
    }
}
