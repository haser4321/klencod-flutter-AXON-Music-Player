
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:audio_service/audio_service.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:permission_handler/permission_handler.dart';

late AxonAudioHandler audioHandler;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  audioHandler = await AudioService.init(
    builder: () => AxonAudioHandler(),
    config: AudioServiceConfig(
      androidNotificationChannelId: 'com.axon.music.playback',
      androidNotificationChannelName: 'AXON Music',
      androidNotificationOngoing: true,
      androidStopForegroundOnPause: false,
    ),
  ) as AxonAudioHandler;

  runApp(const AxonApp());
}

// ==========================================
// SONG MODEL
// ==========================================

class AxonSong {
  final String path;
  final String title;

  AxonSong({
    required this.path,
    required this.title,
  });

  Map<String, dynamic> toJson() {
    return {
      'path': path,
      'title': title,
    };
  }

  factory AxonSong.fromJson(Map<String, dynamic> json) {
    return AxonSong(
      path: json['path'],
      title: json['title'],
    );
  }
}

// ==========================================
// AUDIO HANDLER
// ==========================================

class AxonAudioHandler extends BaseAudioHandler
    with QueueHandler, SeekHandler {

  final AudioPlayer player = AudioPlayer();

  List<AxonSong> songs = [];

  AudioServiceRepeatMode repeatMode =
      AudioServiceRepeatMode.none;

  AxonAudioHandler() {
    player.playbackEventStream.listen((event) {
      _broadcastState();
    });

    player.currentIndexStream.listen((index) {
      if (index != null &&
          index >= 0 &&
          index < songs.length) {
        mediaItem.add(_mediaItem(index));
      }
    });

    player.durationStream.listen((duration) {
      _broadcastState();
    });

    player.processingStateStream.listen((state) {
      _broadcastState();
    });
  }

  MediaItem _mediaItem(int index) {
    final song = songs[index];

    return MediaItem(
      id: song.path,
      title: song.title,
      artist: 'AXON Music',
      album: 'Local Music',
      duration: player.duration,
    );
  }

  Future<void> setPlaylist(
    List<AxonSong> newSongs, {
    int initialIndex = 0,
  }) async {

    songs = List<AxonSong>.from(newSongs);

    if (songs.isEmpty) {
      await player.stop();
      queue.add([]);
      mediaItem.add(null);
      _broadcastState();
      return;
    }

    final items = songs.map((song) {
      return MediaItem(
        id: song.path,
        title: song.title,
        artist: 'AXON Music',
        album: 'Local Music',
      );
    }).toList();

    queue.add(items);

    await player.setAudioSources(
      songs.map((song) {
        return AudioSource.uri(
          Uri.file(song.path),
          tag: MediaItem(
            id: song.path,
            title: song.title,
            artist: 'AXON Music',
          ),
        );
      }).toList(),
      initialIndex: initialIndex.clamp(0, songs.length - 1),
      initialPosition: Duration.zero,
    );

    mediaItem.add(items[
      initialIndex.clamp(0, songs.length - 1)
    ]);

    await player.setLoopMode(
      repeatMode == AudioServiceRepeatMode.one
          ? LoopMode.one
          : LoopMode.off,
    );

    await player.setShuffleModeEnabled(false);

    _broadcastState();
  }

  Future<void> playAt(int index) async {
    if (index < 0 || index >= songs.length) return;

    await player.seek(
      Duration.zero,
      index: index,
    );

    await play();
  }

  void _broadcastState() {
    final playing = player.playing;

    final controls = <MediaControl>[
      MediaControl.skipToPrevious,
      if (playing)
        MediaControl.pause
      else
        MediaControl.play,
      MediaControl.skipToNext,
      MediaControl.custom(
        action: 'axon_repeat',
        name: repeatMode == AudioServiceRepeatMode.one
            ? 'Repeat One'
            : 'Repeat Off',
        androidIcon: 'drawable/ic_repeat',
      ),
    ];

    playbackState.add(
      PlaybackState(
        controls: controls,
        systemActions: const {
          MediaAction.seek,
          MediaAction.seekForward,
          MediaAction.seekBackward,
        },
        androidCompactActionIndices: const [0, 1, 2],
        processingState: {
          ProcessingState.idle:
              AudioProcessingState.idle,
          ProcessingState.loading:
              AudioProcessingState.loading,
          ProcessingState.buffering:
              AudioProcessingState.buffering,
          ProcessingState.ready:
              AudioProcessingState.ready,
          ProcessingState.completed:
              AudioProcessingState.completed,
        }[player.processingState]!,
        playing: playing,
        updatePosition: player.position,
        bufferedPosition: player.bufferedPosition,
        speed: player.speed,
        queueIndex: player.currentIndex,
        repeatMode: repeatMode,
        shuffleMode: AudioServiceShuffleMode.none,
      ),
    );
  }

  @override
  Future<void> play() async {
    if (songs.isEmpty) return;
    await player.play();
  }

  @override
  Future<void> pause() async {
    await player.pause();
  }

  @override
  Future<void> stop() async {
    await player.stop();
    await super.stop();
  }

  @override
  Future<void> seek(Duration position) async {
    await player.seek(position);
  }

  @override
  Future<void> skipToNext() async {
    if (player.hasNext) {
      await player.seekToNext();
    }
  }

  @override
  Future<void> skipToPrevious() async {
    if (player.position.inSeconds > 3) {
      await player.seek(Duration.zero);
    } else if (player.hasPrevious) {
      await player.seekToPrevious();
    }
  }

  @override
  Future<void> setRepeatMode(
    AudioServiceRepeatMode mode,
  ) async {

    repeatMode = mode;

    await player.setLoopMode(
      mode == AudioServiceRepeatMode.one
          ? LoopMode.one
          : LoopMode.off,
    );

    _broadcastState();
  }

  @override
  Future<void> customAction(
    String name, [
    Map<String, dynamic>? extras,
  ]) async {

    if (name == 'axon_repeat') {
      await setRepeatMode(
        repeatMode == AudioServiceRepeatMode.none
            ? AudioServiceRepeatMode.one
            : AudioServiceRepeatMode.none,
      );
    }
  }
}

// ==========================================
// APPLICATION
// ==========================================

class AxonApp extends StatelessWidget {
  const AxonApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'AXON Music',
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0B0D12),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF9B7BFF),
          secondary: Color(0xFF9B7BFF),
          surface: Color(0xFF171A23),
        ),
        useMaterial3: true,
      ),
      home: const AxonHome(),
    );
  }
}

// ==========================================
// HOME SCREEN
// ==========================================

class AxonHome extends StatefulWidget {
  const AxonHome({super.key});

  @override
  State<AxonHome> createState() => _AxonHomeState();
}

class _AxonHomeState extends State<AxonHome> {

  List<AxonSong> songs = [];

  bool loading = true;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    await Permission.notification.request();

    final prefs = await SharedPreferences.getInstance();

    final saved = prefs.getStringList('axon_songs') ?? [];

    final restored = <AxonSong>[];

    for (final path in saved) {
      if (await File(path).exists()) {
        restored.add(
          AxonSong(
            path: path,
            title: _getTitle(path),
          ),
        );
      }
    }

    songs = restored;

    await _saveLibrary();

    if (songs.isNotEmpty) {
      await audioHandler.setPlaylist(songs);
    }

    if (mounted) {
      setState(() {
        loading = false;
      });
    }
  }

  String _getTitle(String path) {
    final name = path.split(Platform.pathSeparator).last;

    final dot = name.lastIndexOf('.');

    if (dot > 0) {
      return name.substring(0, dot);
    }

    return name;
  }

  Future<void> _saveLibrary() async {
    final prefs = await SharedPreferences.getInstance();

    await prefs.setStringList(
      'axon_songs',
      songs.map((song) => song.path).toList(),
    );
  }

  Future<void> _addSongs(List<String> paths) async {

    int added = 0;

    for (final path in paths) {
      if (!path.toLowerCase().endsWith('.mp3')) {
        continue;
      }

      if (!songs.any((song) => song.path == path)) {
        songs.add(
          AxonSong(
            path: path,
            title: _getTitle(path),
          ),
        );

        added++;
      }
    }

    await _saveLibrary();

    await audioHandler.setPlaylist(songs);

    if (mounted) {
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            added == 0
                ? 'No new MP3 files found'
                : '$added songs added to AXON',
          ),
        ),
      );
    }
  }

  Future<void> _pickFiles() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['mp3'],
        allowMultiple: true,
      );

      if (result == null) return;

      final paths = result.files
          .where((file) => file.path != null)
          .map((file) => file.path!)
          .toList();

      await _addSongs(paths);

    } catch (e) {
      _showError('Unable to import music: $e');
    }
  }

  Future<void> _pickFolder() async {
    try {
      final directoryPath =
          await FilePicker.platform.getDirectoryPath(
        dialogTitle: 'Select Music Folder',
      );

      if (directoryPath == null) return;

      final directory = Directory(directoryPath);

      if (!await directory.exists()) {
        _showError('Folder cannot be accessed');
        return;
      }

      final paths = <String>[];

      await for (final entity in directory.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is File &&
            entity.path.toLowerCase().endsWith('.mp3')) {
          paths.add(entity.path);
        }
      }

      await _addSongs(paths);

    } catch (e) {
      _showError('Unable to scan folder: $e');
    }
  }

  void _showError(String message) {
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<void> _removeSong(int index) async {
    final removedPath = songs[index].path;

    final current = audioHandler.player.currentIndex;

    final currentPath = current != null &&
            current >= 0 &&
            current < songs.length
        ? songs[current].path
        : null;

    songs.removeAt(index);

    await _saveLibrary();

    if (currentPath != null && currentPath != removedPath) {
      final newIndex = songs.indexWhere(
        (song) => song.path == currentPath,
      );

      await audioHandler.setPlaylist(
        songs,
        initialIndex: newIndex < 0 ? 0 : newIndex,
      );
    } else {
      await audioHandler.setPlaylist(songs);
    }

    if (mounted) setState(() {});
  }

  String _formatDuration(Duration? duration) {
    if (duration == null) return '--:--';

    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds.remainder(60);

    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF0B0D12),
        title: const Row(
          children: [
            Icon(
              Icons.graphic_eq,
              color: Color(0xFF9B7BFF),
              size: 29,
            ),
            SizedBox(width: 10),
            Text(
              'AXON',
              style: TextStyle(
                fontSize: 23,
                fontWeight: FontWeight.w900,
                letterSpacing: 3,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            onPressed: _pickFiles,
            icon: const Icon(Icons.library_music_outlined),
            tooltip: 'Add music files',
          ),
          IconButton(
            onPressed: _pickFolder,
            icon: const Icon(Icons.folder_open),
            tooltip: 'Add music folder',
          ),
          const SizedBox(width: 8),
        ],
      ),

      body: loading
          ? const Center(
              child: CircularProgressIndicator(),
            )
          : Column(
              children: [
                _buildHeader(),

                Expanded(
                  child: songs.isEmpty
                      ? _buildEmpty()
                      : ListView.builder(
                          padding: const EdgeInsets.only(
                            bottom: 15,
                          ),
                          itemCount: songs.length,
                          itemBuilder: (context, index) {
                            return _buildSongTile(
                              songs[index],
                              index,
                            );
                          },
                        ),
                ),

                _buildPlayer(),
              ],
            ),
    );
  }

  Widget _buildHeader() {
    return Container(
      margin: const EdgeInsets.all(16),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [
            Color(0xFF29203F),
            Color(0xFF171A29),
          ],
        ),
        borderRadius: BorderRadius.circular(22),
      ),
      child: Row(
        children: [
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'YOUR MUSIC',
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.white60,
                    letterSpacing: 2,
                  ),
                ),
                SizedBox(height: 9),
                Text(
                  'Your sound.\nYour world.',
                  style: TextStyle(
                    fontSize: 25,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
          const Icon(
            Icons.headphones_rounded,
            size: 65,
            color: Color(0xFFB69CFF),
          ),
        ],
      ),
    );
  }

  Widget _buildEmpty() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(25),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              Icons.music_off_rounded,
              size: 75,
              color: Colors.white24,
            ),
            const SizedBox(height: 18),
            const Text(
              'Your library is empty',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 9),
            const Text(
              'Add MP3 files or select a music folder.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white54),
            ),
            const SizedBox(height: 25),
            ElevatedButton.icon(
              onPressed: _pickFolder,
              icon: const Icon(Icons.folder_open),
              label: const Text('Choose Music Folder'),
            ),
            TextButton(
              onPressed: _pickFiles,
              child: const Text('Choose Individual Songs'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSongTile(AxonSong song, int index) {
    return StreamBuilder<MediaItem?>(
      stream: audioHandler.mediaItem,
      builder: (context, snapshot) {
        final isCurrent =
            snapshot.data?.id == song.path;

        return Container(
          margin: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 4,
          ),
          decoration: BoxDecoration(
            color: isCurrent
                ? const Color(0xFF252039)
                : const Color(0xFF12151D),
            borderRadius: BorderRadius.circular(14),
          ),
          child: ListTile(
            onTap: () => audioHandler.playAt(index),

            leading: Container(
              width: 45,
              height: 45,
              decoration: BoxDecoration(
                color: const Color(0xFF29223D),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                isCurrent
                    ? Icons.equalizer_rounded
                    : Icons.music_note_rounded,
                color: const Color(0xFFB69CFF),
              ),
            ),

            title: Text(
              song.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: isCurrent
                    ? const Color(0xFFB69CFF)
                    : Colors.white,
              ),
            ),

            subtitle: Text(
              'AXON MUSIC  •  MP3',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.4),
                fontSize: 10,
              ),
            ),

            trailing: IconButton(
              onPressed: () => _removeSong(index),
              icon: const Icon(
                Icons.more_vert,
                color: Colors.white54,
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildPlayer() {
    return StreamBuilder<MediaItem?>(
      stream: audioHandler.mediaItem,
      builder: (context, mediaSnapshot) {
        return StreamBuilder<PlaybackState>(
          stream: audioHandler.playbackState,
          builder: (context, stateSnapshot) {
            final state = stateSnapshot.data;

            final isPlaying = state?.playing ?? false;

            final current = mediaSnapshot.data;

            final currentIndex = state?.queueIndex;

            final currentTitle = current?.title ?? 'Nothing Playing';

            final repeat = state?.repeatMode ??
                AudioServiceRepeatMode.none;

            return Container(
              padding: const EdgeInsets.fromLTRB(
                18, 15, 18, 20,
              ),
              decoration: const BoxDecoration(
                color: Color(0xFF171A23),
                borderRadius: BorderRadius.vertical(
                  top: Radius.circular(24),
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [

                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment:
                              CrossAxisAlignment.start,
                          children: [
                            Text(
                              currentTitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 4),
                            const Text(
                              'AXON MUSIC',
                              style: TextStyle(
                                color: Colors.white38,
                                fontSize: 10,
                                letterSpacing: 2,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Icon(
                        Icons.graphic_eq,
                        color: isPlaying
                            ? const Color(0xFFB69CFF)
                            : Colors.white24,
                      ),
                    ],
                  ),

                  const SizedBox(height: 12),

                  StreamBuilder<Duration>(
                    stream: audioHandler.player.positionStream,
                    builder: (context, positionSnapshot) {
                      final position =
                          positionSnapshot.data ?? Duration.zero;

                      final duration =
                          audioHandler.player.duration ??
                              Duration.zero;

                      final max = duration.inMilliseconds > 0
                          ? duration.inMilliseconds.toDouble()
                          : 1.0;

                      final value = position.inMilliseconds
                          .toDouble()
                          .clamp(0.0, max);

                      return Column(
                        children: [
                          Slider(
                            value: value,
                            max: max,
                            activeColor:
                                const Color(0xFF9B7BFF),
                            inactiveColor: Colors.white12,
                            onChanged: duration.inMilliseconds == 0
                                ? null
                                : (v) {
                                    audioHandler.seek(
                                      Duration(
                                        milliseconds: v.toInt(),
                                      ),
                                    );
                                  },
                          ),
                          Row(
                            mainAxisAlignment:
                                MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                _formatDuration(position),
                                style: const TextStyle(
                                  color: Colors.white38,
                                  fontSize: 11,
                                ),
                              ),
                              Text(
                                _formatDuration(duration),
                                style: const TextStyle(
                                  color: Colors.white38,
                                  fontSize: 11,
                                ),
                              ),
                            ],
                          ),
                        ],
                      );
                    },
                  ),

                  const SizedBox(height: 8),

                  Row(
                    mainAxisAlignment:
                        MainAxisAlignment.spaceBetween,
                    children: [

                      IconButton(
                        tooltip: 'Repeat current song',
                        onPressed: () {
                          audioHandler.setRepeatMode(
                            repeat == AudioServiceRepeatMode.none
                                ? AudioServiceRepeatMode.one
                                : AudioServiceRepeatMode.none,
                          );
                        },
                        icon: Icon(
                          Icons.repeat_one_rounded,
                          color: repeat == AudioServiceRepeatMode.one
                              ? const Color(0xFFB69CFF)
                              : Colors.white38,
                        ),
                      ),

                      IconButton(
                        onPressed: audioHandler.skipToPrevious,
                        icon: const Icon(
                          Icons.skip_previous_rounded,
                          size: 35,
                        ),
                      ),

                      Container(
                        width: 60,
                        height: 60,
                        decoration: const BoxDecoration(
                          color: Color(0xFF9B7BFF),
                          shape: BoxShape.circle,
                        ),
                        child: IconButton(
                          onPressed: songs.isEmpty
                              ? null
                              : () {
                                  if (isPlaying) {
                                    audioHandler.pause();
                                  } else {
                                    if (currentIndex == null) {
                                      audioHandler.playAt(0);
                                    } else {
                                      audioHandler.play();
                                    }
                                  }
                                },
                          icon: Icon(
                            isPlaying
                                ? Icons.pause_rounded
                                : Icons.play_arrow_rounded,
                            color: Colors.white,
                            size: 37,
                          ),
                        ),
                      ),

                      IconButton(
                        onPressed: audioHandler.skipToNext,
                        icon: const Icon(
                          Icons.skip_next_rounded,
                          size: 35,
                        ),
                      ),

                      IconButton(
                        tooltip: 'Play in order',
                        onPressed: () {
                          audioHandler.setRepeatMode(
                            AudioServiceRepeatMode.none,
                          );
                        },
                        icon: const Icon(
                          Icons.playlist_play_rounded,
                          color: Colors.white38,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}
