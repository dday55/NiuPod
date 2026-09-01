import SwiftUI

/// 根视图：未登录显示登录页，已登录进入 iPod 界面
struct RootView: View {
    @Environment(Session.self) private var session
    @Environment(LibraryStore.self) private var library
    @Environment(AudioPlayer.self) private var player

    @State private var nav = PodNavigation()
    @State private var wheel = WheelController()

    private var isBrowsable: Bool { session.isLoggedIn || session.isDemo }

    var body: some View {
        Group {
            if isBrowsable {
                deviceUI
            } else {
                LoginView()
            }
        }
        .environment(nav)
        .environment(wheel)
        .animation(.easeOut(duration: 0.18), value: isBrowsable)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            guard session.isLoggedIn else { return }
            Task {
                await session.reconnect()
                library.reload()
            }
        }
        .onChange(of: isBrowsable) { _, browsable in
            if browsable {
                nav.popToRoot()
                library.isDemo = session.isDemo
                player.isDemo = session.isDemo
                library.reload()
            }
        }
    }

    // MARK: - iPod 机身

    private var deviceUI: some View {
        PodDevice(
            screen: ZStack {
                screen(for: nav.current)
                    .id(nav.depth)
                    .transition(slideTransition)
            },
            wheel: clickWheel
        )
        .animation(.easeOut(duration: 0.22), value: nav.depth)
    }

    private var slideTransition: AnyTransition {
        let insertion: Edge = nav.direction == .forward ? .trailing : .leading
        let removal: Edge = nav.direction == .forward ? .leading : .trailing
        return .asymmetric(insertion: .move(edge: insertion), removal: .move(edge: removal))
    }

    // MARK: - 转盘

    private var clickWheel: ClickWheel {
        ClickWheel(
            onRotate: { delta in wheel.onRotate?(delta) },
            onAngle: { delta in wheel.onAngle?(delta) },
            onMenu: { wheel.onMenu?() },
            onPrevious: { player.previous() },
            onNext: { player.next() },
            onPlayPause: { player.togglePlayPause() },
            onCenter: { wheel.onCenter?() },
            onLongCenter: { wheel.onLongCenter?() }
        )
    }

    // MARK: - 路由

    @ViewBuilder
    private func screen(for route: PodRoute) -> some View {
        switch route {
        case .main:
            MainMenuView()
        case .songs:
            SongsScreen()
        case .albums:
            AlbumsScreen()
        case .albumTracks(let album):
            AsyncTrackListScreen(title: album.name) { await library.tracks(ofAlbum: album.guid) }
        case .artists:
            ArtistsScreen()
        case .artistTracks(let artist):
            AsyncTrackListScreen(title: artist.name) { await library.tracks(ofArtist: artist.guid) }
        case .playlists:
            PlaylistsScreen()
        case .playlistTracks(let playlist):
            AsyncTrackListScreen(title: playlist.name) { await library.tracks(ofPlaylist: playlist.guid) }
        case .favorites:
            FavoritesScreen()
        case .genres:
            GenresScreen()
        case .genreTracks(let genre):
            AsyncTrackListScreen(title: genre.name) { await library.tracks(ofGenre: genre.guid) }
        case .search:
            SearchView()
        case .nowPlaying:
            NowPlayingView()
        case .settings:
            SettingsView()
        case .connection:
            ConnectionView()
        case .about:
            AboutView()
        }
    }
}
