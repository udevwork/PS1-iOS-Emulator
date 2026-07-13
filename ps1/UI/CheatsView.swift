import SwiftUI

/// Редактор GameShark-читов игры: список с тумблерами + форма добавления.
/// Открывается из пауза-меню; игра в этот момент на паузе.
/// Любое изменение сразу сохраняется и применяется к запущенному ядру.
struct CheatsView: View {
    let game: Game
    @Binding var cheats: [Cheat]
    @Environment(\.dismiss) private var dismiss

    @State private var newName = ""
    @State private var newCode = ""

    private var sanitizedCode: String {
        newCode.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    addCard
                    if cheats.isEmpty {
                        emptyHint
                    } else {
                        VStack(spacing: 10) {
                            ForEach($cheats) { $cheat in
                                cheatRow($cheat)
                            }
                        }
                    }
                    footer
                }
                .padding(20)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color(red: 0.07, green: 0.07, blue: 0.1).ignoresSafeArea())
            .navigationTitle("Cheats")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                }
            }
        }
        .preferredColorScheme(.dark)
        // Сохраняем и применяем при любом изменении набора
        .onChange(of: cheats) { _, updated in
            CheatStore.save(updated, for: game)
            EmulatorCore.shared.setCheats(updated)
        }
    }

    // MARK: - Добавление

    private var addCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Cheat")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.85))

            field(placeholder: "Name (optional)", text: $newName, monospaced: false)
            field(placeholder: "GameShark code", text: $newCode, monospaced: true, multiline: true)

            Button {
                addCheat()
            } label: {
                Text("Add")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(sanitizedCode.isEmpty ? .white.opacity(0.08) : .blue.opacity(0.85)))
                    .foregroundStyle(.white.opacity(sanitizedCode.isEmpty ? 0.35 : 1))
            }
            .disabled(sanitizedCode.isEmpty)
        }
        .padding(16)
        .background(card)
    }

    private func field(placeholder: String, text: Binding<String>, monospaced: Bool, multiline: Bool = false) -> some View {
        TextField(placeholder, text: text, axis: multiline ? .vertical : .horizontal)
            .lineLimit(multiline ? 2 : 1, reservesSpace: multiline)
            .textInputAutocapitalization(monospaced ? .characters : .words)
            .autocorrectionDisabled(monospaced)
            .font(.system(size: 15, weight: .regular, design: monospaced ? .monospaced : .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.08), lineWidth: 1))
    }

    private func addCheat() {
        guard !sanitizedCode.isEmpty else { return }
        let trimmedName = newName.trimmingCharacters(in: .whitespaces)
        let name = trimmedName.isEmpty ? "Cheat \(cheats.count + 1)" : trimmedName
        cheats.append(Cheat(name: name, code: sanitizedCode, enabled: true))
        newName = ""
        newCode = ""
        UIHaptics.action()
    }

    // MARK: - Список

    private func cheatRow(_ cheat: Binding<Cheat>) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(cheat.wrappedValue.name)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(cheat.wrappedValue.enabled ? 0.92 : 0.5))
                    .lineLimit(1)
                Text(cheat.wrappedValue.code.replacingOccurrences(of: "\n", with: " "))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.4))
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Toggle("", isOn: cheat.enabled)
                .labelsHidden()
                .tint(.blue)

            Button {
                cheats.removeAll { $0.id == cheat.wrappedValue.id }
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 15))
                    .foregroundStyle(.red.opacity(0.7))
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(card)
    }

    private var emptyHint: some View {
        VStack(spacing: 8) {
            Image(systemName: "wand.and.rays")
                .font(.system(size: 30))
                .foregroundStyle(.white.opacity(0.25))
            Text("No cheats yet")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.6))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private var footer: some View {
        Text("Paste GameShark / Action Replay codes for this game. A bad code may glitch the game — just turn it off.")
            .font(.system(size: 12, design: .rounded))
            .foregroundStyle(.white.opacity(0.35))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 8)
            .padding(.top, 4)
    }

    private var card: some View {
        RoundedRectangle(cornerRadius: 14).fill(.white.opacity(0.05))
    }
}
