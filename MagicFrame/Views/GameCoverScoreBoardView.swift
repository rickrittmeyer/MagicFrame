import SwiftUI

/// Away over home, team names leading, scores trailing and aligned.
struct GameCoverScoreBoardView: View {

    let board: GameCoverScoreBoard
    var font: Font = .caption.weight(.semibold)
    var foregroundStyle: Color = .white

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            scoreRow(team: board.awayTeam, score: board.awayScore)
            scoreRow(team: board.homeTeam, score: board.homeScore)
        }
    }

    private func scoreRow(team: String, score: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(team)
                .font(font)
                .foregroundStyle(foregroundStyle)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(score)
                .font(font)
                .monospacedDigit()
                .foregroundStyle(foregroundStyle)
                .multilineTextAlignment(.trailing)
        }
    }
}
