part of image_crop_plus;

class ImageOptions {
  final int width;
  final int height;

  ImageOptions({
    required this.width,
    required this.height,
  });

  @override
  int get hashCode => Object.hash(width, height);

  @override
  bool operator ==(other) =>
      other is ImageOptions && other.width == width && other.height == height;

  @override
  String toString() => '$runtimeType(width: $width, height: $height)';
}

enum ImageFormat {
  png,
  jpeg;

  int toFFIParam() => switch (this) {
        ImageFormat.png => 0,
        ImageFormat.jpeg => 1,
      };
}

class ImageCrop {
  static const _channel =
      const MethodChannel('plugins.marcin.wroblewscy.eu/image_crop_plus');

  static Future<bool> requestPermissions() => _channel
      .invokeMethod('requestPermissions')
      .then<bool>((result) => result);

  static Future<ImageOptions> getImageOptions({
    required File file,
  }) async {
    final result =
        await _channel.invokeMethod('getImageOptions', {'path': file.path});

    return ImageOptions(
      width: result['width'],
      height: result['height'],
    );
  }

  static Future<File> cropImage(
          {required File file,
          required Rect area,
          double? scale,
          ImageFormat imageFormat = ImageFormat.jpeg}) =>
      _channel.invokeMethod('cropImage', {
        'path': file.path,
        'left': area.left,
        'top': area.top,
        'right': area.right,
        'bottom': area.bottom,
        'imageFormat': imageFormat.toFFIParam(),
        'scale': scale ?? 1.0,
      }).then<File>((result) => File(result));

  static Future<File> sampleImage({
    required File file,
    int? preferredSize,
    int? preferredWidth,
    int? preferredHeight,
    ImageFormat imageFormat = ImageFormat.jpeg,
  }) async {
    assert(() {
      if (preferredSize == null &&
          (preferredWidth == null || preferredHeight == null)) {
        throw ArgumentError(
            'Preferred size or both width and height of a resampled image must be specified.');
      }
      return true;
    }());

    final String path = await _channel.invokeMethod('sampleImage', {
      'path': file.path,
      'maximumWidth': preferredSize ?? preferredWidth,
      'imageFormat': imageFormat.toFFIParam(),
      'maximumHeight': preferredSize ?? preferredHeight,
    });

    return File(path);
  }
}
