import 'orex_update_platform_base.dart';
import 'orex_update_platform_stub.dart'
    if (dart.library.io) 'orex_update_platform_io.dart' as implementation;

export 'orex_update_platform_base.dart';

OrexUpdatePlatform createOrexUpdatePlatform() =>
    implementation.createOrexUpdatePlatform();
