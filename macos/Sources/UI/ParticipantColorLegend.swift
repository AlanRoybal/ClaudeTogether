import SwiftUI

struct ParticipantColorLegend: View {
    let participants: [SessionManager.Participant]
    let localIdentity: UserIdentity
    var compact: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 8) {
            ForEach(participants) { participant in
                HStack(spacing: compact ? 6 : 8) {
                    RoundedRectangle(cornerRadius: compact ? 3 : 4,
                                     style: .continuous)
                        .fill(Color(collabRGB: participant.color))
                        .frame(width: compact ? 12 : 14,
                               height: compact ? 16 : 14)
                        .overlay {
                            RoundedRectangle(cornerRadius: compact ? 3 : 4,
                                             style: .continuous)
                                .stroke(.white.opacity(0.22), lineWidth: 1)
                        }

                    Text(label(for: participant))
                        .font(compact ? .caption2 : .caption)
                        .lineLimit(1)
                }
            }
        }
    }

    private func label(for participant: SessionManager.Participant) -> String {
        let isMe = participant.identity == localIdentity
        return (participant.name.isEmpty ? "(unnamed)" : participant.name)
            + (isMe ? " (you)" : "")
            + (participant.role == .host ? " — host" : "")
    }
}

struct ParticipantColorLegendCard: View {
    let participants: [SessionManager.Participant]
    let localIdentity: UserIdentity

    var body: some View {
        if participants.count > 1 {
            VStack(alignment: .leading, spacing: 6) {
                Text("Cursor Colors")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                ParticipantColorLegend(
                    participants: participants,
                    localIdentity: localIdentity,
                    compact: true)
            }
            .padding(10)
            .background(.ultraThinMaterial,
                        in: RoundedRectangle(cornerRadius: 12,
                                             style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(.white.opacity(0.10), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        }
    }
}

extension Color {
    init(collabRGB packed: UInt32) {
        self.init(
            .sRGB,
            red: Double((packed >> 16) & 0xFF) / 255.0,
            green: Double((packed >> 8) & 0xFF) / 255.0,
            blue: Double(packed & 0xFF) / 255.0,
            opacity: 1.0)
    }
}
