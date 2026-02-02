import Foundation
import AppKit
import AVFoundation

class AudioPlayer: NSObject, AVAudioPlayerDelegate {
    // Pool of audio players to allow overlapping sounds
    private var audioPlayers: [AVAudioPlayer] = []
    private let poolSize = 5

    // Bundled sound file names (without extension)
    private let soundNames = [
        "tibetan-bowl-rubbing-rim",
        "himalayan-singing-bowls",
        "bright-tibetan-bell-ding",
        "singing-bell-hit",
        "bell-meditation"
    ]

    func playRandomChime() {
        guard !soundNames.isEmpty else { return }

        let randomSound = soundNames.randomElement()!
        playSound(named: randomSound)
    }

    func playSound(named name: String) {
        // Try to find the sound file in the bundle
        guard let url = Bundle.main.url(forResource: name, withExtension: "mp3") else {
            print("Sound file not found: \(name).mp3")
            // Fallback: try to play system sound
            playSystemSound()
            return
        }

        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            player.prepareToPlay()
            player.play()

            // Add to pool
            audioPlayers.append(player)

            // Limit pool size by removing finished players
            cleanupFinishedPlayers()

        } catch {
            print("Error playing sound: \(error)")
            playSystemSound()
        }
    }

    private func cleanupFinishedPlayers() {
        // Remove players that have finished playing
        audioPlayers.removeAll { !$0.isPlaying }

        // If still over pool size, remove oldest
        while audioPlayers.count > poolSize {
            let oldest = audioPlayers.removeFirst()
            oldest.stop()
        }
    }

    private func playSystemSound() {
        // Fallback to system bell sound
        NSSound.beep()
    }

    func stop() {
        for player in audioPlayers {
            player.stop()
        }
        audioPlayers.removeAll()
    }

    // MARK: - AVAudioPlayerDelegate

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        // Remove finished player from pool
        audioPlayers.removeAll { $0 === player }
    }
}
