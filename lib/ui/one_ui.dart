import 'package:flutter/material.dart';

import 'theme.dart';

/// Página al estilo One UI: título grande que ocupa la parte alta de la
/// pantalla (zona de lectura) y se contrae al hacer scroll, dejando el
/// contenido al alcance del pulgar.
class OneUiPage extends StatelessWidget {
  final String title;
  final String? subtitle;
  final List<Widget> actions;
  final List<Widget> slivers;
  final Widget? leading;
  final bool showBack;

  const OneUiPage({
    super.key,
    required this.title,
    this.subtitle,
    this.actions = const [],
    required this.slivers,
    this.leading,
    this.showBack = true,
  });

  @override
  Widget build(BuildContext context) {
    final h = MediaQuery.sizeOf(context).height;
    final s = Surfaces.of(context);
    final canPop = showBack && Navigator.of(context).canPop();
    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            pinned: true,
            expandedHeight: (h * 0.30).clamp(200.0, 320.0),
            backgroundColor: s.background,
            surfaceTintColor: Colors.transparent,
            automaticallyImplyLeading: canPop,
            leading: leading,
            actions: [...actions, const SizedBox(width: 8)],
            flexibleSpace: LayoutBuilder(builder: (context, c) {
              final top = MediaQuery.paddingOf(context).top;
              final min = kToolbarHeight + top;
              final max = (h * 0.30).clamp(200.0, 320.0) + top;
              // 1 = expandido, 0 = contraído.
              final t = ((c.maxHeight - min) / (max - min)).clamp(0.0, 1.0);
              return Stack(
                fit: StackFit.expand,
                children: [
                  // Título grande centrado (se desvanece al contraer).
                  Positioned(
                    left: 24,
                    right: 24,
                    bottom: 36 * t + 8,
                    child: Opacity(
                      opacity: Curves.easeIn.transform(t),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(title,
                              textAlign: TextAlign.center,
                              style: Theme.of(context)
                                  .textTheme
                                  .headlineLarge
                                  ?.copyWith(
                                      fontWeight: FontWeight.w400,
                                      fontSize: 34)),
                          if (subtitle != null) ...[
                            const SizedBox(height: 8),
                            Text(subtitle!,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                    color: s.textSecondary, fontSize: 15)),
                          ],
                        ],
                      ),
                    ),
                  ),
                  // Título pequeño en la barra (aparece al contraer).
                  Positioned(
                    left: canPop || leading != null ? 64 : 24,
                    right: 120,
                    top: top,
                    height: kToolbarHeight,
                    child: Opacity(
                      opacity: Curves.easeOut.transform(1 - t),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context)
                                .textTheme
                                .titleLarge
                                ?.copyWith(fontWeight: FontWeight.w700)),
                      ),
                    ),
                  ),
                ],
              );
            }),
          ),
          ...slivers,
          const SliverToBoxAdapter(child: SizedBox(height: 32)),
        ],
      ),
    );
  }
}

/// Tarjeta redondeada de One UI.
class OneCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry margin;
  final VoidCallback? onTap;
  final Color? color;

  const OneCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(20),
    this.margin = const EdgeInsets.fromLTRB(12, 0, 12, 12),
    this.onTap,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final s = Surfaces.of(context);
    return Padding(
      padding: margin,
      child: Material(
        color: color ?? s.card,
        borderRadius: BorderRadius.circular(26),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
  }
}

/// Título de sección pequeño y gris, fuera de las tarjetas.
class SectionLabel extends StatelessWidget {
  final String text;
  final Widget? trailing;
  const SectionLabel(this.text, {super.key, this.trailing});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(28, 14, 20, 8),
        child: Row(
          children: [
            Expanded(
              child: Text(text,
                  style: TextStyle(
                      color: Surfaces.of(context).textSecondary,
                      fontSize: 14,
                      fontWeight: FontWeight.w600)),
            ),
            ?trailing,
          ],
        ),
      );
}

/// Título dentro de una tarjeta, con valor destacado opcional a la derecha.
class CardHeader extends StatelessWidget {
  final String title;
  final String? trailing;
  final Color? trailingColor;
  const CardHeader(this.title, {super.key, this.trailing, this.trailingColor});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Row(
          children: [
            Expanded(
              child: Text(title,
                  style: const TextStyle(
                      fontSize: 17, fontWeight: FontWeight.w700)),
            ),
            if (trailing != null)
              Text(trailing!,
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: trailingColor ??
                          Surfaces.of(context).textSecondary)),
          ],
        ),
      );
}

/// Grupo de filas dentro de una tarjeta con separadores, como los ajustes
/// de Samsung.
class OneGroup extends StatelessWidget {
  final List<Widget> children;
  const OneGroup({super.key, required this.children});

  @override
  Widget build(BuildContext context) {
    final s = Surfaces.of(context);
    return OneCard(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        children: [
          for (var i = 0; i < children.length; i++) ...[
            children[i],
            if (i < children.length - 1)
              Divider(indent: 20, endIndent: 20, color: s.divider),
          ],
        ],
      ),
    );
  }
}

/// Fila de lista One UI: título, descripción y control opcional.
class OneTile extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback? onTap;
  final Color? subtitleColor;

  const OneTile({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.trailing,
    this.onTap,
    this.subtitleColor,
  });

  @override
  Widget build(BuildContext context) {
    final s = Surfaces.of(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        child: Row(
          children: [
            if (leading != null) ...[leading!, const SizedBox(width: 16)],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w500)),
                  if (subtitle != null) ...[
                    const SizedBox(height: 3),
                    Text(subtitle!,
                        style: TextStyle(
                            fontSize: 13.5,
                            color: subtitleColor ?? s.textSecondary)),
                  ],
                ],
              ),
            ),
            if (trailing != null) ...[const SizedBox(width: 12), trailing!],
          ],
        ),
      ),
    );
  }
}

/// Icono dentro de un círculo de color (estilo ajustes Samsung).
class IconBadge extends StatelessWidget {
  final IconData icon;
  final Color color;
  final double size;
  const IconBadge(this.icon, this.color, {super.key, this.size = 40});

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        child: Icon(icon, color: Colors.white, size: size * 0.55),
      );
}

/// Cifra grande con etiqueta, para cuadrículas de indicadores.
class Kpi extends StatelessWidget {
  final String value;
  final String label;
  final IconData? icon;
  final Color? color;
  final String? delta;
  final bool deltaGood;

  const Kpi({
    super.key,
    required this.value,
    required this.label,
    this.icon,
    this.color,
    this.delta,
    this.deltaGood = true,
  });

  @override
  Widget build(BuildContext context) {
    final s = Surfaces.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            if (icon != null) ...[
              Icon(icon, size: 16, color: color ?? s.textSecondary),
              const SizedBox(width: 6),
            ],
            Flexible(
              child: Text(label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: s.textSecondary, fontSize: 13)),
            ),
          ],
        ),
        const SizedBox(height: 4),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(value,
              style: const TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w700,
                  fontFeatures: [FontFeature.tabularFigures()])),
        ),
        if (delta != null)
          Text(delta!,
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: deltaGood ? AppColors.passenger : AppColors.danger)),
      ],
    );
  }
}

/// Etiqueta en forma de píldora.
class Pill extends StatelessWidget {
  final String text;
  final Color color;
  final IconData? icon;
  final bool filled;
  const Pill(this.text, this.color, {super.key, this.icon, this.filled = false});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: filled ? color : color.withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 14, color: filled ? Colors.black : color),
              const SizedBox(width: 4),
            ],
            Text(text,
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: filled ? Colors.black : color)),
          ],
        ),
      );
}

/// Estado vacío con icono grande.
class EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? message;
  const EmptyState(
      {super.key, required this.icon, required this.title, this.message});

  @override
  Widget build(BuildContext context) {
    final s = Surfaces.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 24),
      child: Column(
        children: [
          Icon(icon, size: 56, color: s.textSecondary.withValues(alpha: 0.5)),
          const SizedBox(height: 12),
          Text(title,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          if (message != null) ...[
            const SizedBox(height: 4),
            Text(message!,
                textAlign: TextAlign.center,
                style: TextStyle(color: s.textSecondary)),
          ],
        ],
      ),
    );
  }
}
