import SwiftUI

struct OutputDetailView: View {
    let output: String

    @ViewBuilder
    private var content: some View {
        StructuredAgentOutputView(output: output)
    }

    var body: some View {
        ScrollView {
            content
                .padding()
        }
        .navigationTitle("Agent output")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack {
        OutputDetailView(output: "## Hello\n\nThis is **markdown** and `code`.")
    }
}
