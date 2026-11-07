import Foundation
import SwiftUI

enum Mood: String {
    case idle, thinking, talking, sleeping, excited
}

/// Shared, observable state for the pet's look and its speech bubble.
@MainActor
final class PetState: ObservableObject {
    @Published var mood: Mood = .idle
    @Published var bubble: String? = nil
    @Published var lastInteraction = Date()
    /// True while the mouse is over Pi (shows the full button pill).
    @Published var hovering = false

    private var bubbleTask: Task<Void, Never>?

    func touch() {
        lastInteraction = Date()
        if mood == .sleeping { mood = .idle }
    }

    /// Show a short message above the pet. It hides itself after `seconds`.
    func say(_ text: String, mood newMood: Mood = .talking, seconds: Double = 8) {
        bubble = text
        mood = newMood
        bubbleTask?.cancel()
        bubbleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.bubble = nil
            if self.mood == .talking || self.mood == .excited { self.mood = .idle }
        }
    }

    func hideBubble() {
        bubbleTask?.cancel()
        bubble = nil
        if mood == .talking || mood == .excited { mood = .idle }
    }
}
