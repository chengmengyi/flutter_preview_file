class FileToolsFileInfo {
  const FileToolsFileInfo({
    this.name,
    this.type,
    this.updateTime,
    this.size,
    this.path,
    this.bookmark,
  });

  final String? name;
  final FileToolsDocumentType? type;
  final int? updateTime;
  final int? size;
  final String? path;
  final bool? bookmark;

  FileToolsFileInfo copyWith({
    String? name,
    FileToolsDocumentType? type,
    int? updateTime,
    int? size,
    String? path,
    bool? bookmark,
  }) => FileToolsFileInfo(
    name: name ?? this.name,
    type: type ?? this.type,
    updateTime: updateTime ?? this.updateTime,
    size: size ?? this.size,
    path: path ?? this.path,
    bookmark: bookmark ?? this.bookmark,
  );
}

enum FileToolsDocumentType { all, pdf, word, excel }

enum FileToolsSortType { newest, oldest, az, za }

class FileToolsPdfToImagesZipResult {
  const FileToolsPdfToImagesZipResult({
    required this.fileInfo,
    required this.imageCount,
  });

  final FileToolsFileInfo fileInfo;
  final int imageCount;
}
