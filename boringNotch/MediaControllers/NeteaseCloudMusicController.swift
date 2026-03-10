//
//  NeteaseCloudMusicController.swift
//  boringNotch
//
//  Created for NetEase Cloud Music (网易云音乐) support.
//

import Foundation
import Combine
import SwiftUI

class NeteaseCloudMusicController: MediaControllerProtocol {
    func setFavorite(_ favorite: Bool) async {
        // Not supported
    }

    // MARK: - Properties
    @Published private var playbackState: PlaybackState = PlaybackState(
        bundleIdentifier: "com.netease.163music"
    )

    var playbackStatePublisher: AnyPublisher<PlaybackState, Never> {
        $playbackState.eraseToAnyPublisher()
    }

    var supportsVolumeControl: Bool {
        return false
    }

    var supportsFavorite: Bool { false }

    private var notificationTask: Task<Void, Never>?

    // Constant for time between command and update
    private let commandUpdateDelay: Duration = .milliseconds(25)

    // MARK: - Media Remote Functions
    private let mediaRemoteBundle: CFBundle
    private let MRMediaRemoteSendCommandFunction: @convention(c) (Int, AnyObject?) -> Void
    private let MRMediaRemoteSetElapsedTimeFunction: @convention(c) (Double) -> Void
    private let MRMediaRemoteSetShuffleModeFunction: @convention(c) (Int) -> Void
    private let MRMediaRemoteSetRepeatModeFunction: @convention(c) (Int) -> Void

    private var process: Process?
    private var pipeHandler: JSONLinesPipeHandler?
    private var streamTask: Task<Void, Never>?

    init?() {
        guard
            let bundle = CFBundleCreate(
                kCFAllocatorDefault,
                NSURL(fileURLWithPath: "/System/Library/PrivateFrameworks/MediaRemote.framework")),
            let MRMediaRemoteSendCommandPointer = CFBundleGetFunctionPointerForName(
                bundle, "MRMediaRemoteSendCommand" as CFString),
            let MRMediaRemoteSetElapsedTimePointer = CFBundleGetFunctionPointerForName(
                bundle, "MRMediaRemoteSetElapsedTime" as CFString),
            let MRMediaRemoteSetShuffleModePointer = CFBundleGetFunctionPointerForName(
                bundle, "MRMediaRemoteSetShuffleMode" as CFString),
            let MRMediaRemoteSetRepeatModePointer = CFBundleGetFunctionPointerForName(
                bundle, "MRMediaRemoteSetRepeatMode" as CFString)
        else { return nil }

        mediaRemoteBundle = bundle
        MRMediaRemoteSendCommandFunction = unsafeBitCast(
            MRMediaRemoteSendCommandPointer, to: (@convention(c) (Int, AnyObject?) -> Void).self)
        MRMediaRemoteSetElapsedTimeFunction = unsafeBitCast(
            MRMediaRemoteSetElapsedTimePointer, to: (@convention(c) (Double) -> Void).self)
        MRMediaRemoteSetShuffleModeFunction = unsafeBitCast(
            MRMediaRemoteSetShuffleModePointer, to: (@convention(c) (Int) -> Void).self)
        MRMediaRemoteSetRepeatModeFunction = unsafeBitCast(
            MRMediaRemoteSetRepeatModePointer, to: (@convention(c) (Int) -> Void).self)

        setupNowPlayingObserver()
        Task {
            if isActive() {
                await updatePlaybackInfo()
            }
        }
    }

    deinit {
        notificationTask?.cancel()
        streamTask?.cancel()

        if let pipeHandler = self.pipeHandler {
            Task { await pipeHandler.close() }
        }

        if let process = self.process {
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
        }

        self.process = nil
        self.pipeHandler = nil
    }

    // MARK: - Protocol Implementation
    func play() async {
        MRMediaRemoteSendCommandFunction(0, nil)
    }

    func pause() async {
        MRMediaRemoteSendCommandFunction(1, nil)
    }

    func togglePlay() async {
        if !isActive() {
            openMusicApp()
        }
        MRMediaRemoteSendCommandFunction(2, nil)
    }
    
    func openMusicApp() {
        let bundleID = playbackState.bundleIdentifier

        let workspace = NSWorkspace.shared
        if let appURL = workspace.urlForApplication(withBundleIdentifier: bundleID) {
            let configuration = NSWorkspace.OpenConfiguration()
            workspace.openApplication(at: appURL, configuration: configuration) { (app, error) in
                if let error = error {
                    print("Failed to launch app with bundle ID: \(bundleID), error: \(error)")
                } else {
                    print("Launched app with bundle ID: \(bundleID)")
                }
            }
        } else {
            print("Failed to find app with bundle ID: \(bundleID)")
        }
    }


    func nextTrack() async {
        MRMediaRemoteSendCommandFunction(4, nil)
    }

    func previousTrack() async {
        MRMediaRemoteSendCommandFunction(5, nil)
    }

    func seek(to time: Double) async {
        MRMediaRemoteSetElapsedTimeFunction(time)
    }

    func toggleShuffle() async {
        MRMediaRemoteSetShuffleModeFunction(playbackState.isShuffled ? 1 : 3)
        playbackState.isShuffled.toggle()
    }

    func toggleRepeat() async {
        let newRepeatMode = (playbackState.repeatMode == .off) ? 3 : (playbackState.repeatMode.rawValue - 1)
        playbackState.repeatMode = RepeatMode(rawValue: newRepeatMode) ?? .off
        MRMediaRemoteSetRepeatModeFunction(newRepeatMode)
    }

    func setVolume(_ level: Double) async {
        // NetEase Music does not expose volume control via AppleScript or MRMediaRemote
        playbackState.volume = max(0.0, min(1.0, level))
    }

    func isActive() -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == playbackState.bundleIdentifier
        }
    }

    func updatePlaybackInfo() async {
        // Playback info is pushed via the MRMediaRemote stream; no on-demand query needed.
    }

    // MARK: - Private Methods

    private func setupNowPlayingObserver() {
        notificationTask = Task { @Sendable [weak self] in
            await self?.startMediaRemoteStream()
        }
    }

    private func startMediaRemoteStream() async {
        let process = Process()
        guard
            let scriptURL = Bundle.main.url(forResource: "mediaremote-adapter", withExtension: "pl"),
            let frameworkPath = Bundle.main.privateFrameworksPath?.appending("/MediaRemoteAdapter.framework")
        else {
            assertionFailure("Could not find mediaremote-adapter.pl script or framework path")
            return
        }

        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [scriptURL.path, frameworkPath, "stream"]

        let pipeHandler = JSONLinesPipeHandler()
        process.standardOutput = await pipeHandler.getPipe()

        self.process = process
        self.pipeHandler = pipeHandler

        do {
            try process.run()
            streamTask = Task { [weak self] in
                await self?.processJSONStream()
            }
        } catch {
            assertionFailure("Failed to launch mediaremote-adapter.pl: \(error)")
        }
    }

    private func processJSONStream() async {
        guard let pipeHandler = self.pipeHandler else { return }

        await pipeHandler.readJSONLines(as: NowPlayingUpdate.self) { [weak self] update in
            await self?.handleAdapterUpdate(update)
        }
    }

    private func executeCommand(_ command: String) async {
        let script = "tell application \"NeteaseMusic\" to \(command)"
        try? await AppleScriptHelper.executeVoid(script)
    }

    private func executeAndRefresh(_ command: String) async {
        await executeCommand(command)
        try? await Task.sleep(for: commandUpdateDelay)
        await updatePlaybackInfo()
    }
    

    private func handleAdapterUpdate(_ update: NowPlayingUpdate) async {
        let payload = update.payload

        // Only process updates originating from NetEase Music
        let sourceBundleID = payload.parentApplicationBundleIdentifier ?? payload.bundleIdentifier ?? ""
        if !sourceBundleID.isEmpty && sourceBundleID != playbackState.bundleIdentifier {
            return
        }

        let diff = update.diff ?? false

        var state = PlaybackState(bundleIdentifier: playbackState.bundleIdentifier)

        state.title = payload.title ?? (diff ? self.playbackState.title : "")
        state.artist = payload.artist ?? (diff ? self.playbackState.artist : "")
        state.album = payload.album ?? (diff ? self.playbackState.album : "")
        state.duration = payload.duration ?? (diff ? self.playbackState.duration : 0)

        if let elapsedTime = payload.elapsedTime {
            state.currentTime = elapsedTime
        } else if diff {
            if payload.playing == false {
                let timeSinceLastUpdate = Date().timeIntervalSince(self.playbackState.lastUpdated)
                state.currentTime = self.playbackState.currentTime + (self.playbackState.playbackRate * timeSinceLastUpdate)
            } else {
                state.currentTime = self.playbackState.currentTime
            }
        } else {
            state.currentTime = 0
        }

        if let shuffleMode = payload.shuffleMode {
            state.isShuffled = shuffleMode != 1
        } else if !diff {
            state.isShuffled = false
        } else {
            state.isShuffled = self.playbackState.isShuffled
        }

        if let repeatModeValue = payload.repeatMode {
            state.repeatMode = RepeatMode(rawValue: repeatModeValue) ?? .off
        } else if !diff {
            state.repeatMode = .off
        } else {
            state.repeatMode = self.playbackState.repeatMode
        }

        if let artworkDataString = payload.artworkData {
            state.artwork = Data(
                base64Encoded: artworkDataString.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        } else if !diff {
            state.artwork = nil
        } else {
            state.artwork = self.playbackState.artwork
        }

        if let dateString = payload.timestamp,
           let date = ISO8601DateFormatter().date(from: dateString) {
            state.lastUpdated = date
        } else if !diff {
            state.lastUpdated = Date()
        } else {
            state.lastUpdated = self.playbackState.lastUpdated
        }

        state.playbackRate = payload.playbackRate ?? (diff ? self.playbackState.playbackRate : 1.0)
        state.isPlaying = payload.playing ?? (diff ? self.playbackState.isPlaying : false)
        state.volume = payload.volume ?? (diff ? self.playbackState.volume : 0.5)

        playbackState = state
    }
}
