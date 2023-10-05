part of image_crop_plus;

class CropStyle {
  final int cropGridColumnCount;
  final int cropGridRowCount;
  final Color cropGridColor;
  final Duration cropGridAnimationDuration;
  final double cropOverlayActiveOpacity;
  final double cropOverlayInactiveOpacity;
  final Color cropHandleColor;
  final double cropHandleSize;
  final Color cropBarColor;
  final Size cropBarSize;
  final double cropHandleHitSize;
  final double cropMinFraction;
  final Color overlayColor;
  final Duration settleAnimationDuration;
  final Curve settleAnimationCurve;

  const CropStyle({
    this.cropGridColumnCount = 3,
    this.cropGridRowCount = 3,
    this.cropGridColor = const Color.fromRGBO(0xd0, 0xd0, 0xd0, 0.9),
    this.cropGridAnimationDuration = const Duration(milliseconds: 250),
    this.cropOverlayActiveOpacity = 0.3,
    this.cropOverlayInactiveOpacity = 0.7,
    this.cropHandleColor = const Color.fromRGBO(0xd0, 0xd0, 0xd0, 1.0),
    this.cropHandleSize = 10.0,
    this.cropBarColor = const Color.fromRGBO(0xd0, 0xd0, 0xd0, 0.6),
    this.cropBarSize = const Size(15, 3),
    this.cropHandleHitSize = 48.0,
    this.cropMinFraction = 0.1,
    this.overlayColor = const Color(0x0),
    this.settleAnimationDuration = const Duration(seconds: 1),
    this.settleAnimationCurve = Curves.fastLinearToSlowEaseIn,
  });
}

enum _CropAction { none, moving, cropping, scaling }

enum _CropHandleSide {
  none,
  topLeft,
  top,
  topRight,
  right,
  bottomLeft,
  bottom,
  bottomRight,
  left
}

class Crop extends StatefulWidget {
  final ImageProvider image;
  final double? aspectRatio;
  final double maximumScale;
  final bool alwaysShowGrid;
  final ImageErrorListener? onImageError;
  final bool fixedCropArea;
  final bool ovalCropArea;
  final bool showHandles;
  final CropStyle style;

  const Crop({
    Key? key,
    required this.image,
    this.aspectRatio,
    this.maximumScale = 2.0,
    this.alwaysShowGrid = false,
    this.onImageError,
    this.fixedCropArea = false,
    this.ovalCropArea = false,
    this.showHandles = true,
    this.style = const CropStyle(),
  }) : super(key: key);

  Crop.file(
    File file, {
    Key? key,
    double scale = 1.0,
    this.aspectRatio,
    this.maximumScale = 2.0,
    this.alwaysShowGrid = false,
    this.onImageError,
    this.fixedCropArea = false,
    this.ovalCropArea = false,
    this.showHandles = true,
    this.style = const CropStyle(),
  })  : image = FileImage(file, scale: scale),
        super(key: key);

  Crop.asset(
    String assetName, {
    Key? key,
    AssetBundle? bundle,
    String? package,
    this.aspectRatio,
    this.maximumScale = 2.0,
    this.alwaysShowGrid = false,
    this.onImageError,
    this.fixedCropArea = false,
    this.ovalCropArea = false,
    this.showHandles = true,
    this.style = const CropStyle(),
  })  : image = AssetImage(assetName, bundle: bundle, package: package),
        super(key: key);

  @override
  State<StatefulWidget> createState() => CropState();

  static CropState? of(BuildContext context) =>
      context.findAncestorStateOfType<CropState>();
}

class CropState extends State<Crop> with TickerProviderStateMixin {
  final _surfaceKey = GlobalKey();

  late final AnimationController _activeController;
  late final AnimationController _settleController;

  double _scale = 1.0;
  double _ratio = 1.0;
  Rect _view = Rect.zero;
  Rect _area = Rect.zero;
  Offset _lastFocalPoint = Offset.zero;
  _CropAction _action = _CropAction.none;
  _CropHandleSide _handle = _CropHandleSide.none;

  late double _startScale;
  late Rect _startView;
  late Tween<Rect?> _viewTween;
  late Tween<double> _scaleTween;

  ImageStream? _imageStream;
  ui.Image? _image;
  ImageStreamListener? _imageListener;

  double get scale => _area.shortestSide / _scale;

  Rect? get area => _view.isEmpty
      ? null
      : Rect.fromLTWH(
          _area.left * _view.width / _scale - _view.left,
          _area.top * _view.height / _scale - _view.top,
          _area.width * _view.width / _scale,
          _area.height * _view.height / _scale,
        );

  bool get _isEnabled => _view.isEmpty == false && _image != null;

  // Saving the length for the widest area for different aspectRatio's
  final Map<double, double> _maxAreaWidthMap = {};

  // Counting pointers(number of user fingers on screen)
  int pointers = 0;

  @override
  void initState() {
    super.initState();

    _activeController = AnimationController(
      vsync: this,
      value: widget.alwaysShowGrid ? 1.0 : 0.0,
    )..addListener(() => setState(() {}));
    _settleController = AnimationController(vsync: this)
      ..addListener(_settleAnimationChanged);
  }

  @override
  void dispose() {
    final listener = _imageListener;
    if (listener != null) {
      _imageStream?.removeListener(listener);
    }
    _activeController.dispose();
    _settleController.dispose();

    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    _getImage();
  }

  @override
  void didUpdateWidget(Crop oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.image != oldWidget.image) {
      _getImage();
    } else if (widget.aspectRatio != oldWidget.aspectRatio) {
      _area = _calculateDefaultArea(
        viewWidth: _view.width,
        viewHeight: _view.height,
        imageWidth: _image?.width,
        imageHeight: _image?.height,
      );
    }
    if (widget.alwaysShowGrid != oldWidget.alwaysShowGrid) {
      if (widget.alwaysShowGrid) {
        _activate();
      } else {
        _deactivate();
      }
    }
  }

  void _getImage({bool force = false}) {
    final oldImageStream = _imageStream;
    final newImageStream =
        widget.image.resolve(createLocalImageConfiguration(context));
    _imageStream = newImageStream;
    if (newImageStream.key != oldImageStream?.key || force) {
      final oldImageListener = _imageListener;
      if (oldImageListener != null) {
        oldImageStream?.removeListener(oldImageListener);
      }
      final newImageListener =
          ImageStreamListener(_updateImage, onError: widget.onImageError);
      _imageListener = newImageListener;
      newImageStream.addListener(newImageListener);
    }
  }

  @override
  Widget build(BuildContext context) => ConstrainedBox(
        constraints: const BoxConstraints.expand(),
        child: Listener(
          onPointerDown: (event) => pointers++,
          onPointerUp: (event) => pointers = 0,
          child: GestureDetector(
            key: _surfaceKey,
            behavior: HitTestBehavior.opaque,
            onScaleStart: _isEnabled ? _handleScaleStart : null,
            onScaleUpdate: _isEnabled ? _handleScaleUpdate : null,
            onScaleEnd: _isEnabled ? _handleScaleEnd : null,
            child: CustomPaint(
              painter: _CropPainter(
                image: _image,
                ratio: _ratio,
                view: _view,
                area: _area,
                scale: _scale,
                active: _activeController.value,
                showHandles: widget.showHandles,
                ovalCropArea: widget.ovalCropArea,
                style: widget.style,
              ),
            ),
          ),
        ),
      );

  void _activate() {
    _activeController.animateTo(
      1.0,
      curve: Curves.easeOutCubic,
      duration: widget.style.cropGridAnimationDuration,
    );
  }

  void _deactivate() {
    if (widget.alwaysShowGrid == false) {
      _activeController.animateTo(
        0.0,
        curve: Curves.easeInCubic,
        duration: widget.style.cropGridAnimationDuration,
      );
    }
  }

  Size? get _boundaries {
    final context = _surfaceKey.currentContext;
    if (context == null) {
      return null;
    }

    final size = context.size;
    if (size == null) {
      return null;
    }

    return size -
            Offset(widget.style.cropHandleSize, widget.style.cropHandleSize)
        as Size;
  }

  Offset? _getLocalPoint(Offset point) {
    final context = _surfaceKey.currentContext;
    if (context == null) {
      return null;
    }

    final box = context.findRenderObject() as RenderBox;

    return box.globalToLocal(point);
  }

  void _settleAnimationChanged() {
    setState(() {
      _scale = _scaleTween.transform(_settleController.value);
      final nextView = _viewTween.transform(_settleController.value);
      if (nextView != null) {
        _view = nextView;
      }
    });
  }

  Rect _calculateDefaultArea({
    required int? imageWidth,
    required int? imageHeight,
    required double viewWidth,
    required double viewHeight,
  }) {
    if (imageWidth == null || imageHeight == null) {
      return Rect.zero;
    }

    final imageAspectRatio = imageWidth / imageHeight;
    final widgetAspectRatio = widget.aspectRatio ?? imageAspectRatio;
    double height;
    double width;
    if (widgetAspectRatio > 1) {
      height = 1.0;
      width = (widgetAspectRatio * imageHeight * viewHeight * height) /
          imageWidth /
          viewWidth;
      if (width > 1.0) {
        width = 1.0;
        height = (imageWidth * viewWidth * width) /
            (imageHeight * viewHeight * widgetAspectRatio);
      }
    } else {
      width = 1.0;
      height = (imageWidth * viewWidth * width) /
          (imageHeight * viewHeight * widgetAspectRatio);
      if (height > 1.0) {
        height = 1.0;
        width = (widgetAspectRatio * imageHeight * viewHeight * height) /
            imageWidth /
            viewWidth;
      }
    }
    final aspectRatio = _maxAreaWidthMap[widget.aspectRatio];
    if (aspectRatio != null) {
      _maxAreaWidthMap[aspectRatio] = width;
    }

    return Rect.fromLTWH((1.0 - width) / 2, (1.0 - height) / 2, width, height);
  }

  void _updateImage(ImageInfo imageInfo, bool synchronousCall) {
    WidgetsBinding.instance.addPostFrameCallback((timeStamp) {
      final boundaries = _boundaries;
      if (boundaries == null) {
        return;
      }

      final image = imageInfo.image;

      setState(() {
        _image = image;
        _scale = imageInfo.scale;
        _ratio = max(
          boundaries.width / image.width,
          boundaries.height / image.height,
        );

        final viewWidth = boundaries.width / (image.width * _scale * _ratio);
        final viewHeight = boundaries.height / (image.height * _scale * _ratio);
        _area = _calculateDefaultArea(
          viewWidth: viewWidth,
          viewHeight: viewHeight,
          imageWidth: image.width,
          imageHeight: image.height,
        );
        _view = Rect.fromLTWH(
          (viewWidth - 1.0) / 2,
          (viewHeight - 1.0) / 2,
          viewWidth,
          viewHeight,
        );
        // disable initial magnification
        _scale = _minimumScale ?? 1.0;
        _view = _getViewInBoundaries(_scale);
      });
    });

    WidgetsBinding.instance.ensureVisualUpdate();
  }

  _CropHandleSide _hitCropHandle(Offset? localPoint) {
    final boundaries = _boundaries;
    if (localPoint == null || boundaries == null) {
      return _CropHandleSide.none;
    }

    final viewRect = Rect.fromLTWH(
      boundaries.width * _area.left,
      boundaries.height * _area.top,
      boundaries.width * _area.width,
      boundaries.height * _area.height,
    ).deflate(widget.style.cropHandleSize / 2);

    if (Rect.fromLTWH(
      viewRect.left - widget.style.cropHandleHitSize / 2,
      viewRect.top - widget.style.cropHandleHitSize / 2,
      widget.style.cropHandleHitSize,
      widget.style.cropHandleHitSize,
    ).contains(localPoint)) {
      return _CropHandleSide.topLeft;
    }

    if (Rect.fromLTWH(
      viewRect.topLeft.dx + widget.style.cropHandleHitSize,
      viewRect.top - widget.style.cropHandleHitSize / 2,
      viewRect.width - widget.style.cropHandleHitSize,
      widget.style.cropHandleHitSize,
    ).contains(localPoint)) {
      return _CropHandleSide.top;
    }

    if (Rect.fromLTWH(
      viewRect.right - widget.style.cropHandleHitSize / 2,
      viewRect.top - widget.style.cropHandleHitSize / 2,
      widget.style.cropHandleHitSize,
      widget.style.cropHandleHitSize,
    ).contains(localPoint)) {
      return _CropHandleSide.topRight;
    }

    if (Rect.fromLTWH(
      viewRect.right - widget.style.cropHandleHitSize / 2,
      viewRect.topRight.dy + widget.style.cropHandleHitSize / 2,
      widget.style.cropHandleHitSize,
      viewRect.height - widget.style.cropHandleHitSize,
    ).contains(localPoint)) {
      return _CropHandleSide.right;
    }

    if (Rect.fromLTWH(
      viewRect.left - widget.style.cropHandleHitSize / 2,
      viewRect.bottom - widget.style.cropHandleHitSize / 2,
      widget.style.cropHandleHitSize,
      widget.style.cropHandleHitSize,
    ).contains(localPoint)) {
      return _CropHandleSide.bottomLeft;
    }

    if (Rect.fromLTWH(
      viewRect.bottomLeft.dx + widget.style.cropHandleHitSize,
      viewRect.bottom - widget.style.cropHandleHitSize / 2,
      viewRect.width - widget.style.cropHandleHitSize,
      widget.style.cropHandleHitSize,
    ).contains(localPoint)) {
      return _CropHandleSide.bottom;
    }

    if (Rect.fromLTWH(
      viewRect.right - widget.style.cropHandleHitSize / 2,
      viewRect.bottom - widget.style.cropHandleHitSize / 2,
      widget.style.cropHandleHitSize,
      widget.style.cropHandleHitSize,
    ).contains(localPoint)) {
      return _CropHandleSide.bottomRight;
    }

    if (Rect.fromLTWH(
      viewRect.left - widget.style.cropHandleHitSize / 2,
      viewRect.topLeft.dy + widget.style.cropHandleHitSize,
      widget.style.cropHandleHitSize,
      viewRect.height - widget.style.cropHandleHitSize,
    ).contains(localPoint)) {
      return _CropHandleSide.left;
    }

    return _CropHandleSide.none;
  }

  void _handleScaleStart(ScaleStartDetails details) {
    _activate();
    _settleController.stop(canceled: false);
    _lastFocalPoint = details.focalPoint;
    _action = _CropAction.none;
    _handle = widget.fixedCropArea
        ? _CropHandleSide.none
        : _hitCropHandle(_getLocalPoint(details.focalPoint));
    _startScale = _scale;
    _startView = _view;
  }

  Rect _getViewInBoundaries(double scale) =>
      Offset(
        max(
          min(
            _view.left,
            _area.left * _view.width / scale,
          ),
          _area.right * _view.width / scale - 1.0,
        ),
        max(
          min(
            _view.top,
            _area.top * _view.height / scale,
          ),
          _area.bottom * _view.height / scale - 1.0,
        ),
      ) &
      _view.size;

  double get _maximumScale => widget.maximumScale;

  double? get _minimumScale {
    final boundaries = _boundaries;
    final image = _image;
    if (boundaries == null || image == null) {
      return null;
    }

    final scaleX = boundaries.width * _area.width / (image.width * _ratio);
    final scaleY = boundaries.height * _area.height / (image.height * _ratio);
    return min(_maximumScale, max(scaleX, scaleY));
  }

  void _handleScaleEnd(ScaleEndDetails details) {
    _deactivate();
    final minimumScale = _minimumScale;
    if (minimumScale == null) {
      return;
    }

    final targetScale = _scale.clamp(minimumScale, _maximumScale);
    _scaleTween = Tween<double>(
      begin: _scale,
      end: targetScale,
    );

    _startView = _view;
    _viewTween = RectTween(
      begin: _view,
      end: _getViewInBoundaries(targetScale),
    );

    _settleController.value = 0.0;
    _settleController.animateTo(
      1.0,
      curve: widget.style.settleAnimationCurve,
      duration: widget.style.settleAnimationDuration,
    );
  }

  void _updateArea({
    required _CropHandleSide cropHandleSide,
    double? left,
    double? top,
    double? right,
    double? bottom,
  }) {
    final image = _image;
    if (image == null) {
      return;
    }
    var areaLeft = _area.left + (left ?? 0.0);
    var areaBottom = _area.bottom + (bottom ?? 0.0);
    var areaTop = _area.top + (top ?? 0.0);
    var areaRight = _area.right + (right ?? 0.0);
    double width = areaRight - areaLeft;
    double height = (image.width * _view.width * width) /
        (image.height * _view.height * (widget.aspectRatio ?? 1.0));
    final maxAreaWidth = _maxAreaWidthMap[widget.aspectRatio];
    if ((height >= 1.0 || width >= 1.0) && maxAreaWidth != null) {
      height = 1.0;

      if (cropHandleSide == _CropHandleSide.bottomLeft ||
          cropHandleSide == _CropHandleSide.topLeft) {
        areaLeft = areaRight - maxAreaWidth;
      } else {
        areaRight = areaLeft + maxAreaWidth;
      }
    }

    // ensure minimum rectangle
    if (areaRight - areaLeft < widget.style.cropMinFraction) {
      if (left != null && right != null) {
        final missingFraction =
            widget.style.cropMinFraction - (areaRight - areaLeft);
        areaRight += missingFraction / 2;
        areaLeft -= missingFraction / 2;
      } else if (left != null) {
        areaLeft = areaRight - widget.style.cropMinFraction;
      } else {
        areaRight = areaLeft + widget.style.cropMinFraction;
      }
    }

    if (areaBottom - areaTop < widget.style.cropMinFraction) {
      if (top != null) {
        areaTop = areaBottom - widget.style.cropMinFraction;
      } else {
        areaBottom = areaTop + widget.style.cropMinFraction;
      }
    }

    // adjust to aspect ratio if needed
    final aspectRatio = widget.aspectRatio;
    if (aspectRatio != null && aspectRatio > 0.0) {
      if (top != null) {
        areaTop = areaBottom - height;
        if (areaTop < 0.0) {
          areaTop = 0.0;
          areaBottom = height;
        }
      } else {
        areaBottom = areaTop + height;
        if (areaBottom > 1.0) {
          areaTop = 1.0 - height;
          areaBottom = 1.0;
        }
      }
    }

    // ensure to remain within bounds of the view
    if (areaLeft < 0.0) {
      areaLeft = 0.0;
      areaRight = _area.width;
    }
    if (areaRight > 1.0) {
      areaLeft = 1.0 - _area.width;
      areaRight = 1.0;
    }
    if (areaTop < 0.0) {
      areaTop = 0.0;
      areaBottom = _area.height;
    }
    if (areaBottom > 1.0) {
      areaTop = 1.0 - _area.height;
      areaBottom = 1.0;
    }

    setState(() {
      _area = Rect.fromLTRB(areaLeft, areaTop, areaRight, areaBottom);
    });
  }

  void _handleScaleUpdate(ScaleUpdateDetails details) {
    if (_action == _CropAction.none) {
      if (_handle == _CropHandleSide.none) {
        _action = pointers == 2 ? _CropAction.scaling : _CropAction.moving;
      } else {
        _action = _CropAction.cropping;
      }
    }

    if (_action == _CropAction.cropping) {
      final boundaries = _boundaries;
      if (boundaries == null) {
        return;
      }

      final delta = details.focalPoint - _lastFocalPoint;
      _lastFocalPoint = details.focalPoint;

      final dxRelativeToWidth = delta.dx / boundaries.width;
      final dxRelativeToHeight = delta.dx / boundaries.height;
      final dyRelativeToHeight = delta.dy / boundaries.height;
      final dyRelativeToWidth = delta.dy / boundaries.width;

      final isAspectRatioEnabled = widget.aspectRatio != null;

      if (_handle == _CropHandleSide.topLeft) {
        _updateArea(
          left: dxRelativeToWidth,
          top: dyRelativeToHeight,
          cropHandleSide: _handle,
        );
      } else if (_handle == _CropHandleSide.top) {
        _updateArea(
          top: dyRelativeToHeight,
          left: isAspectRatioEnabled ? dyRelativeToWidth / 2 : 0,
          right: isAspectRatioEnabled ? -dyRelativeToWidth / 2 : 0,
          cropHandleSide: _handle,
        );
      } else if (_handle == _CropHandleSide.topRight) {
        _updateArea(
          top: dyRelativeToHeight,
          right: dxRelativeToWidth,
          cropHandleSide: _handle,
        );
      } else if (_handle == _CropHandleSide.right) {
        _updateArea(
          right: dxRelativeToWidth,
          top: isAspectRatioEnabled ? -dxRelativeToHeight / 2 : 0,
          bottom: isAspectRatioEnabled ? dxRelativeToHeight / 2 : 0,
          cropHandleSide: _handle,
        );
      } else if (_handle == _CropHandleSide.bottomLeft) {
        _updateArea(
          left: dxRelativeToWidth,
          bottom: dyRelativeToHeight,
          cropHandleSide: _handle,
        );
      } else if (_handle == _CropHandleSide.bottom) {
        _updateArea(
          bottom: dyRelativeToHeight,
          left: isAspectRatioEnabled ? -dyRelativeToWidth / 2 : 0,
          right: isAspectRatioEnabled ? dyRelativeToWidth / 2 : 0,
          cropHandleSide: _handle,
        );
      } else if (_handle == _CropHandleSide.bottomRight) {
        _updateArea(
          right: dxRelativeToWidth,
          bottom: dyRelativeToHeight,
          cropHandleSide: _handle,
        );
      } else if (_handle == _CropHandleSide.left) {
        _updateArea(
          left: dxRelativeToWidth,
          top: isAspectRatioEnabled ? dxRelativeToHeight / 2 : 0,
          bottom: isAspectRatioEnabled ? -dxRelativeToHeight / 2 : 0,
          cropHandleSide: _handle,
        );
      }
    } else if (_action == _CropAction.moving) {
      final image = _image;
      if (image == null) {
        return;
      }

      final delta = details.focalPoint - _lastFocalPoint;
      _lastFocalPoint = details.focalPoint;

      setState(() {
        _view = _view.translate(
          delta.dx / (image.width * _scale * _ratio),
          delta.dy / (image.height * _scale * _ratio),
        );
      });
    } else if (_action == _CropAction.scaling) {
      final image = _image;
      final boundaries = _boundaries;
      if (image == null || boundaries == null) {
        return;
      }

      setState(() {
        _scale = _startScale * details.scale;

        final dx = boundaries.width *
            (1.0 - details.scale) /
            (image.width * _scale * _ratio);
        final dy = boundaries.height *
            (1.0 - details.scale) /
            (image.height * _scale * _ratio);

        _view = Rect.fromLTWH(
          _startView.left + dx / 2,
          _startView.top + dy / 2,
          _startView.width,
          _startView.height,
        );
      });
    }
  }
}

class _CropPainter extends CustomPainter {
  final ui.Image? image;
  final Rect view;
  final double ratio;
  final Rect area;
  final double scale;
  final double active;
  final bool showHandles;
  final bool ovalCropArea;
  final CropStyle style;
  late Paint _handlesPaint;
  late Paint _barPaint;
  late Paint _gridPaint;
  late Paint _imagePaint;
  late Paint _overlayPaint;

  _CropPainter({
    required this.image,
    required this.view,
    required this.ratio,
    required this.area,
    required this.scale,
    required this.active,
    required this.showHandles,
    required this.ovalCropArea,
    required this.style,
  }) {
    _handlesPaint = Paint()
      ..isAntiAlias = true
      ..color = style.cropHandleColor;
    _barPaint = Paint()
      ..isAntiAlias = true
      ..color = style.cropBarColor
      ..strokeCap = StrokeCap.round
      ..strokeWidth = style.cropBarSize.height;
    _gridPaint = Paint()
      ..isAntiAlias = false
      ..color =
          style.cropGridColor.withOpacity(style.cropGridColor.opacity * active)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;
    _imagePaint = Paint()..isAntiAlias = false;
    _overlayPaint = Paint()
      ..isAntiAlias = false
      ..color = style.overlayColor;
  }

  @override
  bool shouldRepaint(_CropPainter oldDelegate) {
    return oldDelegate.image != image ||
        oldDelegate.view != view ||
        oldDelegate.ratio != ratio ||
        oldDelegate.area != area ||
        oldDelegate.active != active ||
        oldDelegate.scale != scale;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(
      style.cropHandleSize / 2,
      style.cropHandleSize / 2,
      size.width - style.cropHandleSize,
      size.height - style.cropHandleSize,
    );

    canvas.save();
    canvas.translate(rect.left, rect.top);

    final image = this.image;
    if (image != null) {
      final src = Rect.fromLTWH(
        0.0,
        0.0,
        image.width.toDouble(),
        image.height.toDouble(),
      );
      final dst = Rect.fromLTWH(
        view.left * image.width * scale * ratio,
        view.top * image.height * scale * ratio,
        image.width * scale * ratio,
        image.height * scale * ratio,
      );

      canvas.save();
      canvas.clipRect(Rect.fromLTWH(0.0, 0.0, rect.width, rect.height));
      canvas.drawImageRect(image, src, dst, _imagePaint);
      canvas.restore();
    }

    _adjustPaintsColor(active);
    final boundaries = Rect.fromLTWH(
      rect.width * area.left,
      rect.height * area.top,
      rect.width * area.width,
      rect.height * area.height,
    );
    canvas.drawRect(
        Rect.fromLTRB(0.0, 0.0, rect.width, boundaries.top), _overlayPaint);
    canvas.drawRect(
        Rect.fromLTRB(0.0, boundaries.bottom, rect.width, rect.height),
        _overlayPaint);
    canvas.drawRect(
        Rect.fromLTRB(0.0, boundaries.top, boundaries.left, boundaries.bottom),
        _overlayPaint);
    canvas.drawRect(
        Rect.fromLTRB(
            boundaries.right, boundaries.top, rect.width, boundaries.bottom),
        _overlayPaint);
    if (ovalCropArea) {
      canvas.drawPath(
        Path.combine(
          PathOperation.difference,
          Path()..addRect(boundaries),
          Path()
            ..addOval(
              boundaries,
            )
            ..close(),
        ),
        _overlayPaint,
      );
    }
    if (boundaries.isEmpty == false) {
      // Don't draw the grid since it will be invisible anyway.
      if (active != 0) {
        _drawGrid(canvas, boundaries, _gridPaint);
      }
      // Don't draw the bars if grid is visible.
      // Grid borders will act as top, right, left and bottom bars.
      if (showHandles) {
        if (active != 1) {
          _drawBars(canvas, boundaries, _barPaint);
        }
        _drawHandles(canvas, boundaries, _handlesPaint);
      }
    }

    canvas.restore();
  }

  void _adjustPaintsColor(double gridOpacity) {
    _overlayPaint
      ..color = style.overlayColor.withOpacity(
          style.cropOverlayActiveOpacity * gridOpacity +
              style.cropOverlayInactiveOpacity * (1.0 - gridOpacity));
    _barPaint
      ..color = style.cropBarColor
          .withOpacity(style.cropGridColor.opacity * (1 - gridOpacity));
    _gridPaint
      ..color = style.cropGridColor
          .withOpacity(style.cropGridColor.opacity * gridOpacity);
  }

  void _drawHandles(Canvas canvas, Rect boundaries, Paint paint) {
    canvas.drawOval(
      Rect.fromLTWH(
        boundaries.left - style.cropHandleSize / 2,
        boundaries.top - style.cropHandleSize / 2,
        style.cropHandleSize,
        style.cropHandleSize,
      ),
      paint,
    );

    canvas.drawOval(
      Rect.fromLTWH(
        boundaries.right - style.cropHandleSize / 2,
        boundaries.top - style.cropHandleSize / 2,
        style.cropHandleSize,
        style.cropHandleSize,
      ),
      paint,
    );

    canvas.drawOval(
      Rect.fromLTWH(
        boundaries.right - style.cropHandleSize / 2,
        boundaries.bottom - style.cropHandleSize / 2,
        style.cropHandleSize,
        style.cropHandleSize,
      ),
      paint,
    );

    canvas.drawOval(
      Rect.fromLTWH(
        boundaries.left - style.cropHandleSize / 2,
        boundaries.bottom - style.cropHandleSize / 2,
        style.cropHandleSize,
        style.cropHandleSize,
      ),
      paint,
    );
  }

  void _drawBars(Canvas canvas, Rect boundaries, Paint paint) {
    canvas.drawLine(
      Offset(
        boundaries.topCenter.dx - style.cropBarSize.width / 2,
        boundaries.topCenter.dy,
      ),
      Offset(
        boundaries.topCenter.dx + style.cropBarSize.width / 2,
        boundaries.topCenter.dy,
      ),
      paint,
    );

    canvas.drawLine(
      Offset(
        boundaries.centerRight.dx,
        boundaries.centerRight.dy - style.cropBarSize.width / 2,
      ),
      Offset(
        boundaries.centerRight.dx,
        boundaries.centerRight.dy + style.cropBarSize.width / 2,
      ),
      paint,
    );

    canvas.drawLine(
      Offset(
        boundaries.bottomCenter.dx - style.cropBarSize.width / 2,
        boundaries.bottomCenter.dy,
      ),
      Offset(
        boundaries.bottomCenter.dx + style.cropBarSize.width / 2,
        boundaries.bottomCenter.dy,
      ),
      paint,
    );

    canvas.drawLine(
      Offset(
        boundaries.centerLeft.dx,
        boundaries.centerLeft.dy - style.cropBarSize.width / 2,
      ),
      Offset(
        boundaries.centerLeft.dx,
        boundaries.centerLeft.dy + style.cropBarSize.width / 2,
      ),
      paint,
    );
  }

  void _drawGrid(Canvas canvas, Rect boundaries, Paint paint) {
    final path = Path()
      ..moveTo(boundaries.left, boundaries.top)
      ..lineTo(boundaries.right, boundaries.top)
      ..lineTo(boundaries.right, boundaries.bottom)
      ..lineTo(boundaries.left, boundaries.bottom)
      ..lineTo(boundaries.left, boundaries.top);

    for (var column = 1; column < style.cropGridColumnCount; column++) {
      path
        ..moveTo(
            boundaries.left +
                column * boundaries.width / style.cropGridColumnCount,
            boundaries.top)
        ..lineTo(
            boundaries.left +
                column * boundaries.width / style.cropGridColumnCount,
            boundaries.bottom);
    }

    for (var row = 1; row < style.cropGridRowCount; row++) {
      path
        ..moveTo(boundaries.left,
            boundaries.top + row * boundaries.height / style.cropGridRowCount)
        ..lineTo(boundaries.right,
            boundaries.top + row * boundaries.height / style.cropGridRowCount);
    }

    canvas.drawPath(path, paint);
  }
}
