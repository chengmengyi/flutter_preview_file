# flutter_preview_file

`flutter_preview_file` 是一个用于 Flutter 的文件预览与处理插件，支持 PDF、Word、Excel 的预览，也提供文件转换、拆分、合并、导出图片等常用能力。

## 功能简介

- PDF 预览，基于 `syncfusion_flutter_pdfviewer`
- Word 预览与简单编辑，支持 `doc`、`docx`、`txt`
- Excel 预览与简单编辑，支持 `xlsx`、`xltx`、`csv`
- Word 转 PDF
- PDF 转 Word
- PDF 提取文本
- PDF 拆分、合并、导出图片
- 多图生成 PDF

## 安装

在项目的 `pubspec.yaml` 中加入依赖：

```yaml
dependencies:
  flutter_preview_file:
    git:
      url: https://github.com/chengmengyi/flutter_preview_file.git
```

然后执行：

```bash
flutter pub get
```

如果你已经把插件发布到私有源或本地路径，也可以按自己的方式引入。

## 平台说明

- Android：已包含插件注册配置
- iOS：已包含插件注册配置

当前仓库插件声明的平台为 Android 和 iOS。

## 开始使用

### 1. 导入插件

```dart
import 'package:flutter_preview_file/flutter_preview_file.dart';
```

### 2. 初始化方式

这个插件大部分能力开箱即用，不需要额外的全局初始化。

常见初始化方式有两种：

- 直接使用静态方法，例如 `FlutterPreviewFile.getPdfPageCount(...)`
- 预览 Word / Excel 时创建对应 `Controller`，然后调用 `initialize()`

### 3. 文件路径准备

你需要先拿到本地文件路径，例如：

```dart
const pdfPath = '/path/to/demo.pdf';
const wordPath = '/path/to/demo.docx';
const excelPath = '/path/to/demo.xlsx';
```

## PDF 预览

`PdfFileView` 用于直接展示 PDF 文件。

```dart
import 'package:flutter/material.dart';
import 'package:flutter_preview_file/flutter_preview_file.dart';

class PdfPreviewPage extends StatelessWidget {
  const PdfPreviewPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: PdfFileView(
        filePath: '/path/to/demo.pdf',
      ),
    );
  }
}
```

如果你需要控制翻页、缩放、监听页码变化，可以传入 `PdfViewerController` 和回调：

```dart
final pdfController = PdfViewerController();

PdfFileView(
  filePath: pdfPath,
  controller: pdfController,
  onPageChanged: (details) {
    debugPrint('当前页: ${details.newPageNumber}');
  },
)
```

## Word 预览与编辑

`WordFileView` 需要配合 `WordFileController` 使用。

### 自动初始化

默认 `autoInitialize = true`，组件创建后会自动调用 `controller.initialize()`。

```dart
import 'package:flutter/material.dart';
import 'package:flutter_preview_file/flutter_preview_file.dart';

class WordPreviewPage extends StatefulWidget {
  const WordPreviewPage({super.key});

  @override
  State<WordPreviewPage> createState() => _WordPreviewPageState();
}

class _WordPreviewPageState extends State<WordPreviewPage> {
  late final WordFileController controller;

  @override
  void initState() {
    super.initState();
    controller = WordFileController(filePath: '/path/to/demo.docx');
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        actions: [
          IconButton(
            onPressed: () => controller.enterEditMode(),
            icon: const Icon(Icons.edit),
          ),
          IconButton(
            onPressed: () => controller.save(),
            icon: const Icon(Icons.save),
          ),
        ],
      ),
      body: WordFileView(controller: controller),
    );
  }
}
```

### 手动初始化

如果你希望自己控制初始化时机，可以把 `autoInitialize` 设为 `false`，然后手动调用：

```dart
final controller = WordFileController(filePath: wordPath);
await controller.initialize();
```

```dart
WordFileView(
  controller: controller,
  autoInitialize: false,
)
```

### 常用控制方法

- `initialize()`：初始化文档内容
- `reload()`：重新加载文档
- `enterEditMode()`：进入编辑模式
- `cancelEditing()`：取消编辑
- `save()`：保存编辑结果

## Excel 预览与编辑

`ExcelFileView` 需要配合 `ExcelFileController` 使用。

```dart
import 'package:flutter/material.dart';
import 'package:flutter_preview_file/flutter_preview_file.dart';

class ExcelPreviewPage extends StatefulWidget {
  const ExcelPreviewPage({super.key});

  @override
  State<ExcelPreviewPage> createState() => _ExcelPreviewPageState();
}

class _ExcelPreviewPageState extends State<ExcelPreviewPage> {
  late final ExcelFileController controller;

  @override
  void initState() {
    super.initState();
    controller = ExcelFileController(filePath: '/path/to/demo.xlsx');
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        actions: [
          IconButton(
            onPressed: () => controller.enterEditMode(),
            icon: const Icon(Icons.edit),
          ),
          IconButton(
            onPressed: () => controller.save(),
            icon: const Icon(Icons.save),
          ),
        ],
      ),
      body: ExcelFileView(controller: controller),
    );
  }
}
```

### Excel 常用控制方法

- `initialize()`：初始化表格内容
- `reload()`：重新加载文件
- `enterEditMode()`：进入编辑模式
- `cancelEditing()`：取消编辑
- `selectSheet(sheetName)`：切换工作表
- `save()`：保存编辑结果

## 文件转换

### Word 转 PDF

```dart
final pdfPath = await FlutterPreviewFile.convertWordToPdf(
  inputPath: '/path/to/demo.docx',
  outputPath: '/path/to/output.pdf',
);
```

### PDF 转 Word

```dart
final wordPath = await FlutterPreviewFile.convertPdfToWord(
  inputPath: '/path/to/demo.pdf',
  outputPath: '/path/to/output.docx',
);
```

### 提取 PDF 文本

```dart
final text = await FlutterPreviewFile.extractPdfText(
  inputPath: '/path/to/demo.pdf',
);
```

### HTML 转 PDF

```dart
final result = await FlutterPreviewFile.convertHtmlToPdf(
  html: '<h1>Hello</h1>',
  outputPath: '/path/to/output.pdf',
);
```

## PDF 工具方法

### 获取 PDF 页数

```dart
final pageCount = await FlutterPreviewFile.getPdfPageCount(pdfPath);
```

### 渲染 PDF 页面为图片文件

```dart
final imagePath = await FlutterPreviewFile.renderPdfPageToImage(
  pdfPath: pdfPath,
  pageIndex: 0,
  outputPath: '/path/to/page_1.png',
);
```

### 渲染 PDF 页面为图片字节

```dart
final bytes = await FlutterPreviewFile.renderPdfPageToImageBytes(
  pdfPath: pdfPath,
  pageIndex: 0,
  width: 1080,
);
```

### 合并多个 PDF

```dart
final result = await FlutterPreviewFile.mergePdfFiles(
  fileList: pdfFileList,
  onProgress: (progress) {
    debugPrint('进度: $progress');
  },
);
```

### 拆分 PDF

```dart
final result = await FlutterPreviewFile.splitPdfFile(
  fileInfo: fileInfo,
  selectedPageIndexList: [0, 1, 2],
);
```

## 图片与文件查询

### 查询指定类型文件

```dart
final pdfList = await FlutterPreviewFile.queryFileList(
  FileToolsDocumentType.pdf,
);
```

### 查询全部图片

```dart
final imageList = await FlutterPreviewFile.queryAllImages();
```

### 多张图片生成 PDF

```dart
final result = await FlutterPreviewFile.generatePdfFromImages(
  imageList: imageList,
  outputFileName: 'album_export',
);
```

### 删除文件

```dart
final success = await FlutterPreviewFile.deleteFile('/path/to/demo.pdf');
```

### 重命名文件

```dart
final newFile = await FlutterPreviewFile.renameFile(
  fileInfo: fileInfo,
  newNameWithoutExtension: 'new_name',
);
```

## 常见说明

### 1. 控制器要记得释放

像 `WordFileController`、`ExcelFileController` 这类控制器，建议在页面销毁时调用 `dispose()`。

### 2. 文件必须是本地路径

当前预览和处理能力都依赖本地文件路径，网络地址需要先下载到本地。

### 3. 手动刷新

如果文件在外部被更新了，可以调用：

```dart
await controller.reload();
```

## 导出的主要能力

插件主入口：

- `FlutterPreviewFile`

预览组件：

- `PdfFileView`
- `WordFileView`
- `ExcelFileView`

控制器：

- `WordFileController`
- `ExcelFileController`

模型与任务控制：

- `FileToolsFileInfo`
- `FileToolsDocumentType`
- `FileToolsSortType`
- `FileToolsTaskControl`

## License

MIT
