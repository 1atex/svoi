import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

part 'ui_icon_names.dart';

enum UiIconStyle { outline, duotone }

class UiIconScope extends InheritedNotifier<ValueNotifier<UiIconStyle>> {
  const UiIconScope({super.key, required super.notifier, required super.child});
  static UiIconStyle of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<UiIconScope>()
          ?.notifier
          ?.value ??
      UiIconStyle.outline;
}

class SvoiIcon extends Icon {
  const SvoiIcon(
    super.icon, {
    super.key,
    super.size,
    super.color,
    super.semanticLabel,
    super.textDirection,
    super.applyTextScaling,
    super.shadows,
    this.style,
  });
  final UiIconStyle? style;

  @override
  Widget build(BuildContext context) {
    final name = _uiIconNames[icon];
    if (name == null) return super.build(context);
    final theme = IconTheme.of(context);
    final baseColor = color ?? theme.color ?? const Color(0xfff4f2ed);
    final ink = baseColor.withValues(alpha: baseColor.a * (theme.opacity ?? 1));
    final points = size ?? theme.size ?? 24;
    final scale = applyTextScaling ?? theme.applyTextScaling ?? false;
    final dimension = scale
        ? MediaQuery.textScalerOf(context).scale(points)
        : points;
    final choice = style ?? UiIconScope.of(context);
    return Semantics(
      label: semanticLabel,
      child: ExcludeSemantics(
        child: SizedBox(
          width: dimension,
          height: dimension,
          child: SvgPicture.asset(
            'assets/ui-icons/${choice.name}/$name.svg',
            width: dimension,
            height: dimension,
            colorFilter: ColorFilter.mode(ink, BlendMode.srcIn),
            matchTextDirection: icon?.matchTextDirection ?? false,
            excludeFromSemantics: true,
          ),
        ),
      ),
    );
  }
}
