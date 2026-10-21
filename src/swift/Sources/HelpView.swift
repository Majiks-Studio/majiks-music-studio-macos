import AppKit
import SwiftUI

/// Comprehensive in-app help and documentation system
struct HelpView: View {
    @EnvironmentObject var updateChecker: UpdateChecker
    @State private var searchText = ""
    @State private var selectedSection: HelpSection = .gettingStarted

    enum HelpSection: String, CaseIterable, Identifiable {
        case gettingStarted = "Getting Started"
        case features = "Features"
        case keyboardShortcuts = "Keyboard Shortcuts"
        case troubleshooting = "Troubleshooting"
        case about = "About"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .gettingStarted: return "flag.checkered"
            case .features: return "star.fill"
            case .keyboardShortcuts: return "keyboard"
            case .troubleshooting: return "wrench.and.screwdriver.fill"
            case .about: return "info.circle.fill"
            }
        }

        var searchKeywords: [String] {
            switch self {
            case .gettingStarted:
                return ["welcome", "setup", "first track", "library", "tips", "llm", "ffmpeg"]
            case .features:
                return ["generation", "variants", "models", "export", "playback", "memory"]
            case .keyboardShortcuts:
                return ["shortcuts", "hotkeys", "commands", "keys", "playback", "windows"]
            case .troubleshooting:
                return ["errors", "issues", "fix", "problem", "support", "slow", "failed"]
            case .about:
                return ["version", "credits", "technology", "stack", "paths", "license"]
            }
        }
    }

    private var normalizedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var filteredSections: [HelpSection] {
        if normalizedSearchText.isEmpty {
            return HelpSection.allCases
        }

        return HelpSection.allCases.filter { section in
            section.rawValue.lowercased().contains(normalizedSearchText) ||
            section.searchKeywords.contains { $0.contains(normalizedSearchText) }
        }
    }

    private var activeSection: HelpSection? {
        if filteredSections.contains(selectedSection) {
            return selectedSection
        }
        return filteredSections.first
    }

    var body: some View {
        NavigationSplitView {
            // Sidebar with sections
            List(filteredSections, selection: $selectedSection) { section in
                Label(section.rawValue, systemImage: section.icon)
                    .tag(section)
            }
            .navigationTitle("Help Topics")
            .frame(minWidth: 200)
        } detail: {
            // Main content area
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Search bar
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.secondary)
                        TextField("Search help...", text: $searchText)
                            .textFieldStyle(.plain)
                        if !searchText.isEmpty {
                            Button(action: { searchText = "" }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(10)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(8)
                    .padding(.horizontal)
                    .padding(.top)

                    Divider()

                    // Content based on selected section
                    if let section = activeSection {
                        contentForSection(section)
                            .padding(.horizontal, 24)
                            .padding(.bottom, 24)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("No help topics found")
                                .font(.headline)
                            Text("Try a different search term.")
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 24)
                    }
                }
            }
            .frame(minWidth: 600)
        }
        .onChange(of: searchText) { _, _ in
            guard let first = filteredSections.first, !filteredSections.contains(selectedSection) else {
                return
            }
            selectedSection = first
        }
    }

    @ViewBuilder
    private func contentForSection(_ section: HelpSection) -> some View {
        switch section {
        case .gettingStarted:
            gettingStartedContent
        case .features:
            featuresContent
        case .keyboardShortcuts:
            keyboardShortcutsContent
        case .troubleshooting:
            troubleshootingContent
        case .about:
            aboutContent
        }
    }

    private func openThirdPartyNotices() {
        guard let fallbackURL = URL(string: "https://github.com/Majiks-Studio/majiks-music-studio/blob/main/THIRD-PARTY-NOTICES.md") else {
            return
        }
        let noticesURL = Bundle.main.url(forResource: "THIRD-PARTY-NOTICES", withExtension: "md") ?? fallbackURL
        NSWorkspace.shared.open(noticesURL)
    }

    // MARK: - Getting Started

    private var gettingStartedContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            HelpSectionHeader(title: "Getting Started", icon: "flag.checkered")

            Text("Welcome to Majik's Music Studio! This guide will help you create your first AI-generated music track.")
                .font(.body)

            HelpSubsectionHeader(title: "1. Initial Setup", icon: "gear")

            VStack(alignment: .leading, spacing: 8) {
                BulletPoint("Configure your LLM provider in Settings (⌘,)")
                BulletPoint("Choose from 9 LLM providers including local MLX models, Ollama, OpenRouter, Anthropic, OpenAI, and more")
                BulletPoint("Enter your API key if using OpenRouter")
                BulletPoint("FFmpeg is bundled with the app — no additional installation needed")
            }

            HelpSubsectionHeader(title: "2. Generate Your First Track", icon: "waveform")

            VStack(alignment: .leading, spacing: 8) {
                NumberedStep(number: 1, text: "Open the Chat tab")
                NumberedStep(number: 2, text: "Describe your music: \"Create an upbeat electronic track in Dm, 128 BPM, 3 minutes\"")
                NumberedStep(number: 3, text: "The AI will extract parameters (BPM, key, duration, style)")
                NumberedStep(number: 4, text: "Click \"Send to Studio\" to transfer parameters")
                NumberedStep(number: 5, text: "Adjust parameters in the Studio tab if needed")
                NumberedStep(number: 6, text: "Click \"Generate\" to create your track")
                NumberedStep(number: 7, text: "Your track will appear in the Library when complete")
            }

            HelpSubsectionHeader(title: "3. Using the Library", icon: "music.note.list")

            VStack(alignment: .leading, spacing: 8) {
                BulletPoint("Browse all generated tracks in the Library tab")
                BulletPoint("Use the search bar to find specific tracks")
                BulletPoint("Filter by artist, album, genre, or rating")
                BulletPoint("Sort by date, name, rating, or duration")
                BulletPoint("Click on any track to play it")
                BulletPoint("Rate tracks with stars (1-5)")
                BulletPoint("Export tracks in multiple formats (WAV, FLAC, M4A)")
            }

            HelpSubsectionHeader(title: "4. Quick Tips", icon: "lightbulb.fill")

            VStack(alignment: .leading, spacing: 8) {
                BulletPoint("Use Space to play/pause, ⌘. to stop playback")
                BulletPoint("Press ⌘N to start a new conversation")
                BulletPoint("Use the sparkle button to enhance style descriptions with AI")
                BulletPoint("Try different model sizes for quality vs. speed tradeoffs")
                BulletPoint("Organize tracks with ⌘⇧O for automatic folder structure")
            }
        }
    }

    // MARK: - Features

    private var featuresContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            HelpSectionHeader(title: "Features", icon: "star.fill")

            // Music Generation
            HelpSubsectionHeader(title: "AI Music Generation", icon: "music.note")

            VStack(alignment: .leading, spacing: 8) {
                FeatureItem(
                    title: "LLM-Powered Chat",
                    description: "Describe music in natural language and let AI extract parameters"
                )
                FeatureItem(
                    title: "ACE-Step 1.5 Integration",
                    description: "High-quality music generation using state-of-the-art DiT + LLM models"
                )
                FeatureItem(
                    title: "Multiple Variants",
                    description: "Generate 1-5 variations of the same track simultaneously"
                )
                FeatureItem(
                    title: "Language Model Selection",
                    description: "Choose between 0.6B (Fast), 1.7B (Balanced), or 4B (Best Quality) models based on your VRAM"
                )
                FeatureItem(
                    title: "CFG Guidance Control",
                    description: "Adjust prompt adherence from 1.0-20.0 (default 4.5). Lower = creative, Higher = strict"
                )
                FeatureItem(
                    title: "AI Caption Enhancement",
                    description: "Click the sparkle button to expand simple style descriptions into rich, detailed captions"
                )
            }

            Divider()

            // Library Management
            HelpSubsectionHeader(title: "Library Management", icon: "books.vertical.fill")

            VStack(alignment: .leading, spacing: 8) {
                FeatureItem(
                    title: "Three View Modes",
                    description: "Switch between List, Column Browser (Artist > Album > Tracks), and Album Grid views"
                )
                FeatureItem(
                    title: "Procedural Album Art",
                    description: "150 unique geometric patterns automatically generated for each track"
                )
                FeatureItem(
                    title: "Powerful Search",
                    description: "Search across title, caption, artist, album, and genre in real-time"
                )
                FeatureItem(
                    title: "Advanced Filtering",
                    description: "Filter by artist, album, genre, or rating (5★, 4★+, 3★+, Unrated)"
                )
                FeatureItem(
                    title: "8 Sort Options",
                    description: "Sort by date, name, rating, or duration (ascending/descending)"
                )
                FeatureItem(
                    title: "Star Ratings",
                    description: "Rate tracks 1-5 stars with persistent storage"
                )
                FeatureItem(
                    title: "Auto-Organization",
                    description: "Automatically organize tracks into Artist/Album folder structure"
                )
            }

            Divider()

            // Audio Export
            HelpSubsectionHeader(title: "Audio Export System", icon: "square.and.arrow.up")

            VStack(alignment: .leading, spacing: 8) {
                Text("Export Formats:")
                    .font(.headline)

                FormatItem(format: "WAV", description: "Lossless, 48kHz stereo, uncompressed")
                FormatItem(format: "FLAC", description: "Lossless, compressed (~33% smaller than WAV)")
                FormatItem(format: "M4A/AAC", description: "Lossy, 128k or 256k bitrate options")
                FormatItem(format: "MP3", description: "Lossy, 192k or 320k bitrate options")
                Text("Export Features:")
                    .font(.headline)
                    .padding(.top, 8)

                BulletPoint("Single or batch export")
                BulletPoint("Quality selection for lossy formats")
                BulletPoint("Custom output location")
                BulletPoint("Progress tracking")
                BulletPoint("Comprehensive error handling")
            }

            Divider()

            // Playback
            HelpSubsectionHeader(title: "Audio Playback", icon: "play.circle.fill")

            VStack(alignment: .leading, spacing: 8) {
                FeatureItem(
                    title: "Full Playback Controls",
                    description: "Play/Pause/Stop with visual feedback"
                )
                FeatureItem(
                    title: "Seek Bar",
                    description: "Drag to any position in the track"
                )
                FeatureItem(
                    title: "Volume Control",
                    description: "Adjust from 0-100%"
                )
                FeatureItem(
                    title: "Playing Indicator",
                    description: "Green badge shows which track is currently playing"
                )
            }

            Divider()

            // Generation Queue
            HelpSubsectionHeader(title: "Generation Queue", icon: "list.number")

            VStack(alignment: .leading, spacing: 8) {
                FeatureItem(
                    title: "Multi-Variant Queue",
                    description: "Queue multiple generation jobs and track progress for each variant"
                )
                FeatureItem(
                    title: "Cancel & Reorder",
                    description: "Cancel running jobs or reorder the queue while generation is in progress"
                )
                FeatureItem(
                    title: "Remote Server Support",
                    description: "Generate on local GPU, remote ACE-Step servers, or both simultaneously"
                )
            }

            Divider()

            // Window Management
            HelpSubsectionHeader(title: "Window Management", icon: "macwindow")

            VStack(alignment: .leading, spacing: 8) {
                FeatureItem(
                    title: "Tabbed Interface",
                    description: "Chat | Studio | Library | Publisher tabs in main window"
                )
                FeatureItem(
                    title: "Pop-out Windows",
                    description: "Open Library (⌘⌥L) or Studio (⌘⌥S) in separate windows"
                )
                FeatureItem(
                    title: "Multi-Display Support",
                    description: "Use library on one screen, studio on another"
                )
                FeatureItem(
                    title: "Synchronized State",
                    description: "All windows share the same data and update in real-time"
                )
            }

            Divider()

            // Publisher Features
            HelpSubsectionHeader(title: "Publisher (Optional Upgrade)", icon: "arrow.up.circle.fill")

            VStack(alignment: .leading, spacing: 8) {
                FeatureItem(
                    title: "Publish to majiks.online",
                    description: "Upload and distribute your tracks to the majiks.online marketplace"
                )
                FeatureItem(
                    title: "Catalogue Grouping",
                    description: "Browse your published catalogue organized by Artist > Album > Tracks with filtering and sort controls"
                )
                FeatureItem(
                    title: "Album Editing",
                    description: "Edit album assignments directly in the catalogue edit sheet"
                )
                FeatureItem(
                    title: "Artist Profiles",
                    description: "Create and manage multiple artist identities for publishing"
                )
                FeatureItem(
                    title: "Provenance Certificates",
                    description: "Cryptographic proof of first publication with verifiable hashes"
                )
                FeatureItem(
                    title: "Creator Dashboard",
                    description: "Track sales, earnings, payouts, and catalogue analytics"
                )
                FeatureItem(
                    title: "DMCA Reporting",
                    description: "File infringement claims directly from the app"
                )
            }

            Divider()

            // Art Studio Integration
            HelpSubsectionHeader(title: "Art Studio Integration", icon: "paintbrush.fill")

            VStack(alignment: .leading, spacing: 8) {
                FeatureItem(
                    title: "Generate Track Artwork",
                    description: "Request cover art from Majik's Art Studio directly from the catalogue edit sheet"
                )
                FeatureItem(
                    title: "Health Check",
                    description: "Automatically detects whether Art Studio is running on localhost:8420"
                )
                FeatureItem(
                    title: "Auto-Disable",
                    description: "Art Studio buttons are disabled when the companion app is not running"
                )
            }

            Divider()

            // LLM Resource Management
            HelpSubsectionHeader(title: "Memory Optimization", icon: "memorychip")

            VStack(alignment: .leading, spacing: 8) {
                FeatureItem(
                    title: "Unload LLM",
                    description: "Free VRAM by unloading the language model when not needed"
                )
                FeatureItem(
                    title: "Unload All Models",
                    description: "Maximum memory savings by unloading everything"
                )
                FeatureItem(
                    title: "Reload LLM",
                    description: "Reload with your chosen model size when needed again"
                )
                FeatureItem(
                    title: "Automatic Cleanup",
                    description: "MPS cache clearing after model operations"
                )
            }

            Divider()

            // Library Location
            HelpSubsectionHeader(title: "Library Location", icon: "externaldrive.fill")

            VStack(alignment: .leading, spacing: 8) {
                FeatureItem(
                    title: "Custom Library Location",
                    description: "Move your entire audio library to an external drive or custom folder from Settings"
                )
                FeatureItem(
                    title: "Portable Library",
                    description: "Take your library with you on external drives — all audio, artwork, and metadata move together"
                )
            }
        }
    }

    // MARK: - Keyboard Shortcuts

    private var keyboardShortcutsContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            HelpSectionHeader(title: "Keyboard Shortcuts", icon: "keyboard")

            Text("Master these shortcuts to work faster and more efficiently.")
                .font(.body)

            HelpSubsectionHeader(title: "General", icon: "app.fill")
            ShortcutTable(shortcuts: [
                ("⌘N", "New Conversation", "Start a fresh chat session"),
                ("⌘,", "Settings", "Open application settings"),
                ("⌘Q", "Quit", "Exit Majik's Music Studio"),
                ("⌘?", "Help", "Open this help window")
            ])

            HelpSubsectionHeader(title: "Library", icon: "music.note.list")
            ShortcutTable(shortcuts: [
                ("⌘⇧A", "New Artist", "Create a new artist category"),
                ("⌘⇧L", "New Album", "Create a new album"),
                ("⌘⇧O", "Organize All Files", "Auto-organize tracks into Artist/Album folders"),
                ("⌘⇧F", "Show Audio Folder", "Open audio folder in Finder"),
                ("⌘F", "Search Library", "Focus the library search bar"),
                ("⌘I", "Import Audio", "Import audio files into the library")
            ])

            HelpSubsectionHeader(title: "Playback", icon: "play.circle")
            ShortcutTable(shortcuts: [
                ("Space", "Play/Pause", "Toggle playback of current track"),
                ("⌘.", "Stop", "Stop playback and reset position"),
                ("⌘→", "Next Track", "Skip to next track in queue"),
                ("⌘←", "Previous Track", "Skip to previous track")
            ])

            HelpSubsectionHeader(title: "Windows", icon: "macwindow")
            ShortcutTable(shortcuts: [
                ("⌘⌥L", "Toggle Library Window", "Open/close pop-out library window"),
                ("⌘⌥S", "Toggle Studio Window", "Open/close pop-out studio window")
            ])

            HelpSubsectionHeader(title: "Publisher", icon: "arrow.up.circle")
            ShortcutTable(shortcuts: [
                ("⌘⇧P", "Publish Selected", "Publish the selected track to majiks.online"),
                ("⌘R", "Refresh", "Refresh the current publisher section")
            ])

            Divider()

            InfoBox(
                title: "Pro Tip",
                icon: "lightbulb.fill",
                color: .blue,
                content: "The Space bar works globally - you can play/pause from any tab or window. Use ⌘. to stop playback completely."
            )
        }
    }

    // MARK: - Troubleshooting

    private var troubleshootingContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            HelpSectionHeader(title: "Troubleshooting", icon: "wrench.and.screwdriver.fill")

            Text("Common issues and their solutions.")
                .font(.body)

            // Generation Issues
            HelpSubsectionHeader(title: "Generation Issues", icon: "exclamationmark.triangle.fill")

            TroubleshootItem(
                problem: "Generation fails with memory error",
                solution: "Your system may not have enough VRAM. Try:\n• Use the 0.6B model instead of 1.7B or 4B\n• Unload unused models with the Memory menu\n• Close other GPU-intensive applications\n• Reduce the number of variants being generated"
            )

            TroubleshootItem(
                problem: "Caption enhancement not working",
                solution: "Ensure:\n• Your LLM provider is configured in Settings\n• You have a valid API key for OpenRouter (if using)\n• The backend process is running (check status in UI)\n• You have internet connectivity for cloud LLMs"
            )

            TroubleshootItem(
                problem: "Generation is very slow",
                solution: "Speed can be improved by:\n• Using the 0.6B model (faster but lower quality)\n• Reducing inference steps in Studio settings\n• Generating fewer variants at once\n• Ensuring no other processes are using GPU"
            )

            Divider()

            // Export Issues
            HelpSubsectionHeader(title: "Export Issues", icon: "square.and.arrow.up.trianglebadge.exclamationmark")

            TroubleshootItem(
                problem: "Export fails with FFmpeg error",
                solution: "FFmpeg is bundled with the app. If exports fail:\n• Restart the application to re-initialize FFmpeg\n• Check that the app bundle is intact (not moved out of Applications)\n• Try exporting to WAV first (uses native audio, no FFmpeg needed)"
            )

            TroubleshootItem(
                problem: "Exported files have no sound",
                solution: "This usually indicates:\n• The source file may be corrupted\n• Try exporting to WAV format first (lossless)\n• Re-generate the track if issue persists"
            )

            Divider()

            // Playback Issues
            HelpSubsectionHeader(title: "Playback Issues", icon: "speaker.slash.fill")

            TroubleshootItem(
                problem: "No audio during playback",
                solution: "Check:\n• System volume is not muted\n• App volume slider is above 0%\n• macOS audio output device is correct\n• Track file exists in audio folder"
            )

            TroubleshootItem(
                problem: "Crackling or distorted audio",
                solution: "Try:\n• Adjusting the app volume lower\n• Checking system audio settings\n• Re-generating the track\n• Exporting to FLAC and importing back"
            )

            Divider()

            // Library Issues
            HelpSubsectionHeader(title: "Library Issues", icon: "books.vertical.fill")

            TroubleshootItem(
                problem: "Tracks missing from library",
                solution: "The app auto-scans on launch, but you can:\n• Restart the application\n• Check ~/Library/Application Support/MajiksMusicStudio/audio/\n• Use ⌘⇧F to open audio folder and verify files exist\n• Check library.json for corruption"
            )

            TroubleshootItem(
                problem: "Album art not showing correctly",
                solution: "Album art is procedurally generated:\n• Each track has a unique, deterministic design\n• Restart the app to regenerate all artwork\n• Album art patterns are based on track IDs"
            )

            Divider()

            // Model Requirements
            HelpSubsectionHeader(title: "Model & System Requirements", icon: "desktopcomputer")

            VStack(alignment: .leading, spacing: 12) {
                Text("VRAM Requirements:")
                    .font(.headline)

                ModelRequirement(model: "0.6B (Fast)", vram: "< 8GB", notes: "Good for systems with limited VRAM")
                ModelRequirement(model: "1.7B (Balanced)", vram: "8-16GB", notes: "Recommended default, best quality/speed balance")
                ModelRequirement(model: "4B (Best Quality)", vram: "> 16GB", notes: "Highest quality, requires high-end GPU")

                Text("Additional Requirements:")
                    .font(.headline)
                    .padding(.top, 8)

                BulletPoint("macOS 14.0 (Sonoma) or later with Apple Silicon")
                BulletPoint("Metal Performance Shaders support")
                BulletPoint("Python 3.12 for backend")
                BulletPoint("At least 20GB free disk space for models and audio")
            }

            Divider()

            InfoBox(
                title: "Still Having Issues?",
                icon: "questionmark.circle.fill",
                color: .orange,
                content: "Check the logs at ~/Library/Logs/MajiksMusicStudio/ or report issues on GitHub. Include your macOS version, hardware specs, and error messages."
            )
        }
    }

    // MARK: - About

    private var aboutContent: some View {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"

        return VStack(alignment: .leading, spacing: 16) {
            HelpSectionHeader(title: "About Majik's Music Studio", icon: "info.circle.fill")

            VStack(spacing: 20) {
                // App Icon and Name
                VStack(spacing: 12) {
                    Image(systemName: "music.note")
                        .font(.system(size: 64))
                        .foregroundColor(.blue)

                    Text("Majik's Music Studio")
                        .font(.title)
                        .fontWeight(.bold)

                    Text("Version \(version)")
                        .font(.title3)
                        .foregroundColor(.secondary)

                    Button(action: {
                        Task {
                            await updateChecker.checkForUpdates(silent: false)
                        }
                    }) {
                        Label("Check for Updates", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.bordered)

                    Button(action: { openThirdPartyNotices() }) {
                        Label("Third-party notices", systemImage: "doc.text")
                    }
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)

                Divider()

                // Description
                VStack(alignment: .leading, spacing: 12) {
                    Text("Professional AI-powered music creation for macOS")
                        .font(.headline)

                    Text("Majik's Music Studio combines the power of state-of-the-art AI music generation with an intuitive, native macOS interface. Create high-quality music tracks through natural language descriptions, organize your library like a pro, and export in all major formats.")
                        .font(.body)
                        .foregroundColor(.secondary)
                }

                Divider()

                // Technical Stack
                HelpSubsectionHeader(title: "Technology Stack", icon: "cpu")

                VStack(alignment: .leading, spacing: 8) {
                    TechStackItem(category: "Frontend", tech: "Swift 6.0 with strict concurrency")
                    TechStackItem(category: "UI Framework", tech: "SwiftUI for native macOS")
                    TechStackItem(category: "Graphics", tech: "Canvas API for procedural art")
                    TechStackItem(category: "Backend", tech: "Python 3.12 with type hints")
                    TechStackItem(category: "AI Model", tech: "ACE-Step 1.5 (DiT + 5Hz LLM)")
                    TechStackItem(category: "ML Framework", tech: "PyTorch with Metal Performance Shaders")
                    TechStackItem(category: "Audio", tech: "FFmpeg for format conversion")
                    TechStackItem(category: "Storage", tech: "JSON persistence with auto-save")
                }

                Divider()

                // Credits
                HelpSubsectionHeader(title: "Credits & Acknowledgments", icon: "heart.fill")

                VStack(alignment: .leading, spacing: 8) {
                    CreditItem(entity: "ACE-Step Team", contribution: "Amazing music generation model")
                    CreditItem(entity: "OpenRouter", contribution: "LLM provider infrastructure")
                    CreditItem(entity: "Anthropic", contribution: "Claude API for intelligent chat")
                    CreditItem(entity: "Apple", contribution: "Swift, SwiftUI, and Metal Performance Shaders")
                    CreditItem(entity: "FFmpeg Project", contribution: "Audio processing and conversion")
                    CreditItem(entity: "PyTorch Team", contribution: "Deep learning framework")
                }

                Divider()

                // File Locations
                HelpSubsectionHeader(title: "File Locations", icon: "folder.fill")

                VStack(alignment: .leading, spacing: 8) {
                    FileLocationItem(
                        path: "~/Library/Application Support/MajiksMusicStudio/",
                        description: "Main application data directory"
                    )
                    FileLocationItem(
                        path: "~/Library/Application Support/MajiksMusicStudio/audio/",
                        description: "Generated audio files and organized library"
                    )
                    FileLocationItem(
                        path: "~/Library/Application Support/MajiksMusicStudio/staging/",
                        description: "Temporary workspace (auto-cleaned after 30 days)"
                    )
                    FileLocationItem(
                        path: "~/Library/Logs/MajiksMusicStudio/",
                        description: "Application logs for troubleshooting"
                    )
                }

                Divider()

                // Statistics
                HelpSubsectionHeader(title: "Statistics", icon: "chart.bar.fill")

                LazyVGrid(columns: [
                    GridItem(.flexible()),
                    GridItem(.flexible())
                ], spacing: 16) {
                    StatCard(number: "9", label: "Keyboard Shortcuts")
                    StatCard(number: "6", label: "Export Formats")
                    StatCard(number: "8", label: "Sort Options")
                    StatCard(number: "5", label: "Filter Categories")
                    StatCard(number: "150", label: "Album Art Designs")
                    StatCard(number: "3", label: "Model Sizes")
                }

                Divider()

                // The Majiks Suite
                HelpSubsectionHeader(title: "The Majiks Suite", icon: "sparkles")

                VStack(alignment: .leading, spacing: 6) {
                    Text("Three companion apps that work together to take a song from idea to published release.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.bottom, 4)
                }

                // Songwriter
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "text.quote")
                            .foregroundColor(.orange)
                            .frame(width: 20)
                        Text("Majik's Songwriter")
                            .font(.headline)
                    }

                    Text("An AI songwriter that turns your conversations, articles, and ideas into original song lyrics. Uses 14 creative strategies to find stories worth telling, then sends finished songs directly to Music Studio for generation.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    FeatureItem(
                        title: "Studio Bridge",
                        description: "Sends lyrics, metadata, and generation parameters directly to your Music Studio library"
                    )
                    FeatureItem(
                        title: "iMessage & RSS Sources",
                        description: "Mines your text conversations and news feeds for songwriting inspiration"
                    )
                    FeatureItem(
                        title: "Knowledge Graph",
                        description: "Builds a map of people, themes, and emotions to find deeper connections"
                    )
                }

                Divider()
                    .padding(.vertical, 4)

                // Music Studio (this app)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "music.note.house.fill")
                            .foregroundColor(.blue)
                            .frame(width: 20)
                        Text("Majik's Music Studio")
                            .font(.headline)
                        Text("(this app)")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }

                    Text("AI music generation powered by ACE-Step. Create full songs from text descriptions, manage your library, and publish to majiks.online.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Divider()
                    .padding(.vertical, 4)

                // Art Studio
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "paintbrush.fill")
                            .foregroundColor(.purple)
                            .frame(width: 20)
                        Text("Majik's Art Studio")
                            .font(.headline)
                    }

                    Text("AI artwork generation using FLUX on Apple Silicon. Creates track covers, album art, and artist profile images with genre-aware styling and automatic text compositing.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    FeatureItem(
                        title: "Built-in Integration",
                        description: "Music Studio detects Art Studio automatically on localhost:8420 and adds artwork buttons throughout the app"
                    )
                    FeatureItem(
                        title: "Genre-Aware Prompting",
                        description: "16 genre-to-style mappings ensure artwork matches your music's aesthetic"
                    )
                }

                Divider()
                    .padding(.vertical, 4)

                // Pipeline
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.triangle.branch")
                            .foregroundColor(.green)
                            .frame(width: 20)
                        Text("The Pipeline")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                    }

                    HStack(spacing: 4) {
                        ForEach(["Songwriter", "Music Studio", "Art Studio", "majiks.online"], id: \.self) { step in
                            Text(step)
                                .font(.caption2)
                                .fontWeight(.medium)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.accentColor.opacity(0.1))
                                .clipShape(Capsule())

                            if step != "majiks.online" {
                                Image(systemName: "arrow.right")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }

                    Text("Each app is standalone, but together they form a complete creative pipeline from lyric to published release.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Divider()

                // Made with Love
                VStack(spacing: 8) {
                    Text("Built with ❤️ by")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Text("Magic Unicorn Unconventional Technology & Stuff Inc.")
                        .font(.headline)
                        .foregroundColor(.blue)

                    Text("Production Ready • Ship it!")
                        .font(.caption)
                        .foregroundColor(.green)
                        .fontWeight(.bold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)

                Divider()

                // Support Development
                VStack(spacing: 12) {
                    HStack {
                        Image(systemName: "heart.circle.fill")
                            .foregroundColor(.pink)
                        Text("Support Development")
                            .font(.headline)
                    }

                    Text("Majik's Music Studio is independently developed. If you enjoy using it, consider supporting continued development.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)

                    HStack(spacing: 16) {
                        Button(action: {
                            if let url = URL(string: "https://buymeacoffee.com/aaronyo") {
                                NSWorkspace.shared.open(url)
                            }
                        }) {
                            HStack(spacing: 6) {
                                Image(systemName: "cup.and.saucer.fill")
                                Text("Buy Me a Coffee")
                            }
                            .font(.body)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Color.orange.opacity(0.15))
                            .foregroundColor(.orange)
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)

                        Button(action: {
                            if let url = URL(string: "https://github.com/MagicUnicornInc") {
                                NSWorkspace.shared.open(url)
                            }
                        }) {
                            HStack(spacing: 6) {
                                Image(systemName: "chevron.left.forwardslash.chevron.right")
                                Text("GitHub")
                            }
                            .font(.body)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Color.primary.opacity(0.08))
                            .foregroundColor(.primary)
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)

                Divider()

                // Support & Contact
                VStack(spacing: 12) {
                    HStack {
                        Image(systemName: "envelope.fill")
                            .foregroundColor(.blue)
                        Text("Support")
                            .font(.headline)
                    }

                    VStack(spacing: 4) {
                        Text("Need help or have questions?")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Button(action: {
                            if let url = URL(string: "mailto:support@magicunicorn.tech") {
                                NSWorkspace.shared.open(url)
                            }
                        }) {
                            Text("support@magicunicorn.tech")
                                .font(.body)
                                .foregroundColor(.blue)
                        }
                        .buttonStyle(.plain)
                    }

                    Text("Publishing to majiks.online is free — just sign in with your Unicorn Commander account in the Publisher tab.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
        }
    }
}

// MARK: - Supporting Views

struct HelpSectionHeader: View {
    let title: String
    let icon: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title)
                .foregroundColor(.blue)
            Text(title)
                .font(.title)
                .fontWeight(.bold)
        }
        .padding(.bottom, 4)
    }
}

struct HelpSubsectionHeader: View {
    let title: String
    let icon: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.headline)
                .foregroundColor(.blue)
            Text(title)
                .font(.headline)
        }
        .padding(.top, 8)
    }
}

struct BulletPoint: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•")
                .foregroundColor(.secondary)
            Text(text)
                .foregroundColor(.secondary)
        }
    }
}

struct NumberedStep: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number).")
                .fontWeight(.semibold)
                .foregroundColor(.blue)
                .frame(width: 20, alignment: .trailing)
            Text(text)
                .foregroundColor(.secondary)
        }
    }
}

struct FeatureItem: View {
    let title: String
    let description: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline)
            Text(description)
                .font(.body)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }
}

struct FormatItem: View {
    let format: String
    let description: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(format)
                .fontWeight(.semibold)
                .foregroundColor(.blue)
                .frame(width: 80, alignment: .leading)
            Text(description)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 2)
    }
}

struct ShortcutTable: View {
    let shortcuts: [(String, String, String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(shortcuts, id: \.0) { shortcut in
                HStack(alignment: .top, spacing: 16) {
                    Text(shortcut.0)
                        .font(.system(.body, design: .monospaced))
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.blue)
                        .cornerRadius(6)
                        .frame(width: 100, alignment: .leading)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(shortcut.1)
                            .fontWeight(.medium)
                        Text(shortcut.2)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

struct TroubleshootItem: View {
    let problem: String
    let solution: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundColor(.orange)
                Text(problem)
                    .font(.headline)
            }

            Text(solution)
                .font(.body)
                .foregroundColor(.secondary)
                .padding(.leading, 24)
        }
        .padding(.vertical, 8)
    }
}

struct ModelRequirement: View {
    let model: String
    let vram: String
    let notes: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(model)
                .fontWeight(.semibold)
                .frame(width: 140, alignment: .leading)

            Text(vram)
                .foregroundColor(.blue)
                .fontWeight(.medium)
                .frame(width: 80, alignment: .leading)

            Text(notes)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }
}

struct InfoBox: View {
    let title: String
    let icon: String
    let color: Color
    let content: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(color)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundColor(color)
                Text(content)
                    .font(.body)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(color.opacity(0.1))
        .cornerRadius(8)
    }
}

struct TechStackItem: View {
    let category: String
    let tech: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(category + ":")
                .fontWeight(.semibold)
                .frame(width: 120, alignment: .leading)
            Text(tech)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 2)
    }
}

struct CreditItem: View {
    let entity: String
    let contribution: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(entity)
                .fontWeight(.semibold)
                .frame(width: 140, alignment: .leading)
            Text(contribution)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 2)
    }
}

struct FileLocationItem: View {
    let path: String
    let description: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(path)
                .font(.system(.body, design: .monospaced))
                .foregroundColor(.blue)
            Text(description)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }
}

struct StatCard: View {
    let number: String
    let label: String

    var body: some View {
        VStack(spacing: 8) {
            Text(number)
                .font(.system(size: 36, weight: .bold))
                .foregroundColor(.blue)
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }
}

// MARK: - Preview

#Preview {
    HelpView()
        .environmentObject(UpdateChecker())
        .frame(width: 900, height: 700)
}
