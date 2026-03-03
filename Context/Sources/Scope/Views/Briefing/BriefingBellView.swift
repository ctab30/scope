import SwiftUI

struct BriefingBellView: View {
    @EnvironmentObject var briefingService: BriefingService
    @Binding var showDrawer: Bool

    var body: some View {
        Button {
            showDrawer.toggle()
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "bell.fill")
                    .font(.system(size: 14))
                    .foregroundColor(showDrawer ? .accentColor : .secondary)

                if briefingService.unreadCount > 0 {
                    Text("\(min(briefingService.unreadCount, 99))")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.orange))
                        .offset(x: 6, y: -6)
                }
            }
        }
        .buttonStyle(.plain)
        .help("Morning Briefing")
    }
}
