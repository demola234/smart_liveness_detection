import 'package:camera/camera.dart';
import 'package:face_liveness_detection/face_liveness_detection.dart';
import 'package:flutter/widgets.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

import '../services/camera_service.dart';
import '../services/face_detection_service.dart';
import '../services/motion_service.dart';

/// Controller for liveness detection session
class LivenessController extends ChangeNotifier {
  /// Camera service
  final CameraService _cameraService;

  /// Face detection service
  final FaceDetectionService _faceDetectionService;

  /// Motion service
  final MotionService _motionService;

  /// Available cameras
  final List<CameraDescription> _cameras;

  /// Configuration
  LivenessConfig _config;

  /// Theme
  LivenessTheme _theme;

  /// Liveness session
  LivenessSession _session;

  /// Message for face centering guidance
  String _faceCenteringMessage = '';

  /// Whether a face is currently detected
  bool _isFaceDetected = false;

  /// Whether currently processing an image
  bool _isProcessing = false;

  /// Current status message
  String _statusMessage = 'Initializing...';

  /// Callback for when a challenge is completed
  final ChallengeCompletedCallback? _onChallengeCompleted;

  /// Callback for when liveness verification is completed
  final LivenessCompletedCallback? _onLivenessCompleted;

  /// Whether verification was successful (after completion)
  bool _isVerificationSuccessful = false;

  /// Constructor
  LivenessController({
    required List<CameraDescription> cameras,
    LivenessConfig? config,
    LivenessTheme? theme,
    CameraService? cameraService,
    FaceDetectionService? faceDetectionService,
    MotionService? motionService,
    List<ChallengeType>? challengeTypes,
    ChallengeCompletedCallback? onChallengeCompleted,
    LivenessCompletedCallback? onLivenessCompleted,
  })  : _cameras = cameras,
        _config = config ?? const LivenessConfig(),
        _theme = theme ?? const LivenessTheme(),
        _cameraService = cameraService ?? CameraService(config: config),
        _faceDetectionService =
            faceDetectionService ?? FaceDetectionService(config: config),
        _motionService = motionService ?? MotionService(config: config),
        _onChallengeCompleted = onChallengeCompleted,
        _onLivenessCompleted = onLivenessCompleted,
        _session = LivenessSession(
          challenges: LivenessSession.generateRandomChallenges(
              config ?? const LivenessConfig()),
        ) {
    _initialize();
  }

  /// Initialize the controller and services
  Future<void> _initialize() async {
    try {
      await _cameraService.initialize(_cameras);
      _motionService.startAccelerometerTracking();

      _cameraService.controller?.startImageStream(_processCameraImage);

      notifyListeners();
    } catch (e) {
      debugPrint('Error initializing liveness controller: $e');
      _statusMessage = 'Error initializing camera: $e';
      notifyListeners();
    }
  }

  /// Process images from the camera stream
  Future<void> _processCameraImage(CameraImage image) async {
    if (_isProcessing || !_cameraService.isInitialized) return;

    _isProcessing = true;

    try {
      if (_session.isExpired(_config.maxSessionDuration)) {
        _session = _session.reset(_config);
        _faceDetectionService.resetTracking();
        _motionService.resetTracking();
        notifyListeners();
        _isProcessing = false;
        return;
      }

      _cameraService.calculateLightingCondition(image);

      final hasScreenGlare = _cameraService.detectScreenGlare(image);
      if (hasScreenGlare) {
        debugPrint(
            'Detected potential screen glare, possible spoofing attempt');
      }

      final camera = _cameras.firstWhere(
        (camera) => camera.lensDirection == CameraLensDirection.front,
        orElse: () => _cameras.first,
      );

      final faces = await _faceDetectionService.processImage(image, camera);

      if (faces.isNotEmpty) {
        final face = faces.first;
        _isFaceDetected = true;

        final screenSize = Size(
          image.width.toDouble(),
          image.height.toDouble(),
        );

        bool isCentered =
            _faceDetectionService.checkFaceCentering(face, screenSize);

        _updateFaceCenteringGuidance(face, screenSize);

        if (_session.state == LivenessState.centeringFace && isCentered) {
          _processLivenessDetection(face);
        } else if (_session.state != LivenessState.centeringFace) {
          _processLivenessDetection(face);
        }
      } else {
        _isFaceDetected = false;
        _faceCenteringMessage = 'No face detected';
      }

      notifyListeners();
    } catch (e) {
      debugPrint('Error processing camera image: $e');
    } finally {
      _isProcessing = false;
    }
  }

  /// Update face centering guidance message
  void _updateFaceCenteringGuidance(Face face, Size screenSize) {
    final screenCenterX = screenSize.width / 2;
    final screenCenterY = screenSize.height / 2 - screenSize.height * 0.05;

    final faceBox = face.boundingBox;
    final faceCenterX = faceBox.left + faceBox.width / 2;
    final faceCenterY = faceBox.top + faceBox.height / 2;

    final ovalHeight = screenSize.height * 0.55;
    final ovalWidth = ovalHeight * 0.75;
    final faceWidthRatio = faceBox.width / ovalWidth;

    final isHorizontallyOff =
        (faceCenterX - screenCenterX).abs() > screenSize.width * 0.1;
    final isVerticallyOff =
        (faceCenterY - screenCenterY).abs() > screenSize.height * 0.1;
    final isTooBig = faceWidthRatio > 0.9;
    final isTooSmall = faceWidthRatio < 0.5;

    if (isTooBig) {
      _faceCenteringMessage = 'Move farther away';
    } else if (isTooSmall) {
      _faceCenteringMessage = 'Move closer';
    } else if (isHorizontallyOff) {
      if (faceCenterX < screenCenterX) {
        _faceCenteringMessage = 'Move right';
      } else {
        _faceCenteringMessage = 'Move left';
      }
    } else if (isVerticallyOff) {
      if (faceCenterY < screenCenterY) {
        _faceCenteringMessage = 'Move down';
      } else {
        _faceCenteringMessage = 'Move up';
      }
    } else {
      _faceCenteringMessage = 'Perfect! Hold still';
    }
  }

  /// Process liveness detection for the current state
  void _processLivenessDetection(Face face) {
    if (!_cameraService.isLightingGood) {
      _statusMessage = 'Please move to a better lit area';
      return;
    }

    switch (_session.state) {
      case LivenessState.initial:
        _session.state = LivenessState.centeringFace;
        _statusMessage = 'Position your face within the oval';
        break;

      case LivenessState.centeringFace:
        if (_faceDetectionService.isFaceCentered) {
          _session.state = LivenessState.performingChallenges;
          _updateStatusMessage();
        } else {
          _statusMessage = _faceCenteringMessage;
        }
        break;

      case LivenessState.performingChallenges:
        if (_session.currentChallengeIndex >= _session.challenges.length) {
          _completeSession();
          break;
        }

        final currentChallenge = _session.currentChallenge!;
        bool challengePassed = _faceDetectionService.detectChallengeCompletion(
            face, currentChallenge.type);

        if (challengePassed) {
          currentChallenge.isCompleted = true;
          _session.currentChallengeIndex++;

          // Notify via callback
          _onChallengeCompleted?.call(currentChallenge.type.toString());

          _updateStatusMessage();
        }
        break;

      case LivenessState.completed:
        break;
    }
  }

  /// Complete the liveness session
  void _completeSession() {
    _session.state = LivenessState.completed;

    bool motionValid = _motionService
        .verifyMotionCorrelation(_faceDetectionService.headAngleReadings);

    _isVerificationSuccessful = motionValid;

    if (!motionValid) {
      debugPrint('Potential spoofing detected: Face moved but device didn\'t');
    }

    _statusMessage = 'Liveness verification complete!';

    // Notify via callback
    _onLivenessCompleted
        ?.call(_session.sessionId, _isVerificationSuccessful, {});
  }

  /// Update the current status message
  void _updateStatusMessage() {
    if (_session.currentChallenge != null) {
      _statusMessage = _session.currentChallenge!.instruction;
    } else {
      _statusMessage = 'Processing verification...';
    }
  }

  /// Reset the session
  void resetSession() {
    _session = _session.reset(_config);
    _faceDetectionService.resetTracking();
    _motionService.resetTracking();
    _statusMessage = 'Initializing...';
    _isVerificationSuccessful = false;
    notifyListeners();
  }

  /// Update configuration
  void updateConfig(LivenessConfig config) {
    _config = config;
    _cameraService.updateConfig(config);
    _faceDetectionService.updateConfig(config);
    _motionService.updateConfig(config);
    notifyListeners();
  }

  /// Update theme
  void updateTheme(LivenessTheme theme) {
    _theme = theme;
    notifyListeners();
  }

  /// Whether camera is initialized
  bool get isInitialized => _cameraService.isInitialized;

  /// Whether a face is currently detected
  bool get isFaceDetected => _isFaceDetected;

  /// Whether lighting conditions are good
  bool get isLightingGood => _cameraService.isLightingGood;

  /// Current status message
  String get statusMessage => _statusMessage;

  /// Current state of liveness detection
  LivenessState get currentState => _session.state;

  /// Progress as percentage (0.0-1.0)
  double get progress => _session.getProgressPercentage();

  /// Session ID
  String get sessionId => _session.sessionId;

  /// Camera controller
  CameraController? get cameraController => _cameraService.controller;

  /// Face centering message
  String get faceCenteringMessage => _faceCenteringMessage;

  /// Current liveness session
  LivenessSession get session => _session;

  /// Current configuration
  LivenessConfig get config => _config;

  /// Current theme
  LivenessTheme get theme => _theme;

  /// Whether verification was successful
  bool get isVerificationSuccessful => _isVerificationSuccessful;

  /// Current lighting value (0.0-1.0)
  double get lightingValue => _cameraService.lightingValue;

  /// Capture current image as a file
  Future<XFile?> captureImage() async {
    if (_cameraService.isInitialized && _cameraService.controller != null) {
      try {
        final XFile file = await _cameraService.controller!.takePicture();
        return file;
      } catch (e) {
        debugPrint('Error capturing image: $e');
        return null;
      }
    }
    return null;
  }

  /// Clean up resources
  @override
  void dispose() {
    _cameraService.dispose();
    _faceDetectionService.dispose();
    _motionService.dispose();
    super.dispose();
  }
}
