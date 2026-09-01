import SwiftUI

/// 主菜单（iPod 开机后的第一屏）
struct MainMenuView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(AudioPlayer.self) private var player
    @Environment(Session.self) private var session
    @Environment(PodNavigation.self) private var nav

    @State private var selected = 0

    private struct Entry {
        let id: String
        let title: String
        let badge: String?
        let action: () -> Void
    }

    private var entries: [Entry] {
        var list: [Entry] = [
            Entry(id: "songs", title: "歌曲", badge: count(library.songs.count, unit: "首")) {
                nav.push(.songs)
            },
            Entry(id: "albums", title: "专辑", badge: count(library.albums.count, unit: "张")) {
                nav.push(.albums)
            },
            Entry(id: "artists", title: "歌手", badge: count(library.artists.count, unit: "位")) {
                nav.push(.artists)
            },
            Entry(id: "playlists", title: "歌单", badge: count(library.playlists.count, unit: "个")) {
                nav.push(.playlists)
            },
            Entry(id: "genres", title: "风格", badge: count(library.genres.count, unit: "个")) {
                nav.push(.genres)
            },
            Entry(id: "favorites", title: "收藏", badge: count(library.favorites.count, unit: "首")) {
                nav.push(.favorites)
            },
            Entry(id: "search", title: "搜索", badge: nil) { nav.push(.search) },
            Entry(id: "shuffle",
                  title: player.shuffle ? "关闭随机播放" : "随机播放歌曲",
                  badge: player.shuffle ? "已开启" : nil) {
                guard !library.songs.isEmpty else { return }
                if player.shuffle {
                    player.setShuffle(false, orderedQueue: library.songs)
                } else {
                    player.setShuffle(true)
                    player.playQueue(library.songs.shuffled(), startingAt: 0)
                    nav.push(.nowPlaying)
                }
            },
        ]

        if let track = player.currentTrack {
            list.append(Entry(id: "nowplaying", title: track.title, badge: nil) {
                nav.push(.nowPlaying)
            })
        }

        list.append(Entry(id: "settings", title: "设置", badge: nil) { nav.push(.settings) })
        return list
    }

    private func count(_ value: Int, unit: String) -> String? {
        value > 0 ? "\(value) \(unit)" : nil
    }

    var body: some View {
        PodScreen(title: "NiuPod") {
            PodMenuList(items: items, selected: $selected) { index in
                entries[index].action()
            }
        }
        .podWheel(selected: $selected, count: entries.count) { index in
            entries[index].action()
        } onMenu: {
            // 根菜单上没有上一级，MENU 不响应
        }
        .onChange(of: entries.count) { _, newCount in
            if selected >= newCount { selected = max(0, newCount - 1) }
        }
    }

    private var items: [PodMenuItem] {
        entries.map { entry in
            PodMenuItem(
                id: entry.id,
                title: entry.title,
                subtitleRight: entry.badge,
                showDisclosure: entry.id != "shuffle",
                isNowPlayingRow: entry.id == "nowplaying"
            )
        }
    }
}
