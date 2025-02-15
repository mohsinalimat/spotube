import 'package:html/dom.dart';
import 'package:http/http.dart' as http;
import 'package:html/parser.dart';
import 'package:collection/collection.dart';
import 'package:spotube/helpers/contains-text-in-bracket.dart';
import 'package:spotube/helpers/getLyrics.dart';
import 'package:spotube/models/Logger.dart';
import 'package:spotube/models/SpotubeTrack.dart';

final logger = getLogger("getTimedLyrics");

class SubtitleSimple {
  Uri uri;
  String name;
  List<LyricSlice> lyrics;
  int rating;
  SubtitleSimple({
    required this.uri,
    required this.name,
    required this.lyrics,
    required this.rating,
  });
}

class LyricSlice {
  Duration time;
  String text;

  LyricSlice({required this.time, required this.text});

  @override
  String toString() {
    return "LyricsSlice({time: $time, text: $text})";
  }
}

const baseUri = "https://www.rentanadviser.com/subtitles";

Future<SubtitleSimple?> getTimedLyrics(SpotubeTrack track) async {
  final artistNames =
      track.artists?.map((artist) => artist.name!).toList() ?? [];
  final query = getTitle(
    track.name!,
    artists: artistNames,
  );

  logger.v("[Searching Subtitle] $query");

  final searchUri = Uri.parse("$baseUri/subtitles4songs.aspx").replace(
    queryParameters: {"q": query},
  );

  final res = await http.get(searchUri);
  final document = parse(res.body);
  final results =
      document.querySelectorAll("#tablecontainer table tbody tr td a");

  final rateSortedResults = results.map((result) {
    final title = result.text.trim().toLowerCase();
    int points = 0;
    final hasAllArtists = track.artists
            ?.map((artist) => artist.name!)
            .every((artist) => title.contains(artist.toLowerCase())) ??
        false;
    final hasTrackName = title.contains(track.name!.toLowerCase());
    final isNotLive = !containsTextInBracket(title, "live");
    final exactYtMatch = title == track.ytTrack.title.toLowerCase();
    if (exactYtMatch) points = 7;
    for (final criteria in [hasTrackName, hasAllArtists, isNotLive]) {
      if (criteria) points++;
    }
    return {"result": result, "points": points};
  }).sorted((a, b) => (b["points"] as int).compareTo(a["points"] as int));

  // not result was found at all
  if (rateSortedResults.first["points"] == 0) {
    logger.e("[Subtitle not found] ${track.name}");
    return Future.error("Subtitle lookup failed", StackTrace.current);
  }

  final topResult = rateSortedResults.first["result"] as Element;
  final subtitleUri =
      Uri.parse("$baseUri/${topResult.attributes["href"]}&type=lrc");

  logger.v("[Selected subtitle] ${topResult.text} | $subtitleUri");

  final lrcDocument = parse((await http.get(subtitleUri)).body);
  final lrcList = lrcDocument
          .querySelector("#ctl00_ContentPlaceHolder1_lbllyrics")
          ?.innerHtml
          .replaceAll(RegExp(r'<h3>.*</h3>'), "")
          .split("<br>")
          .map((e) {
        e = e.trim();
        final regexp = RegExp(r'\[.*\]');
        final timeStr = regexp
            .firstMatch(e)
            ?.group(0)
            ?.replaceAll(RegExp(r'\[|\]'), "")
            .trim()
            .split(":");
        final minuteSeconds = timeStr?.last.split(".");

        return LyricSlice(
            time: Duration(
              minutes: int.parse(timeStr?.first ?? "0"),
              seconds: int.parse(minuteSeconds?.first ?? "0"),
              milliseconds: int.parse(minuteSeconds?.last ?? "0"),
            ),
            text: e.split(regexp).last);
      }).toList() ??
      [];

  final subtitle = SubtitleSimple(
    name: topResult.text.trim(),
    uri: subtitleUri,
    lyrics: lrcList,
    rating: rateSortedResults.first["points"] as int,
  );

  return subtitle;
}
