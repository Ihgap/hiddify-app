import 'package:humanizer/humanizer.dart';

extension ByteFormatter on int {
  String size() => bytes().toString();

  // GB (десятичные, «GB»), а не GiB (двоичные «GiB») — привычнее пользователю.
  static final _sizeOfFormat = InformationSizeFormat(permissibleValueUnits: {InformationUnit.gigabyte});

  String sizeGB() => _sizeOfFormat.format(bytes());

  String sizeOf(int total) => "${_sizeOfFormat.format(bytes())} / ${_sizeOfFormat.format(total.bytes())}";

  bool isInfinitSize() => bytes().terabytes.toDouble() > 10;

  static final _rateFormat = InformationRateFormat(permissibleRateUnits: {RateUnit.second});

  String speed() => _rateFormat.format(bytes().per(const Duration(seconds: 1)));
}
