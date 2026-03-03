import "dart:ui" show ImageFilter;

import "package:flutter/material.dart";

import "nzm_theme.dart";

String nzmFormatNumber(dynamic value) {
  if (value == null) {
    return "0";
  }
  if (value is int) {
    return value.toString().replaceAllMapped(
          RegExp(r"\B(?=(\d{3})+(?!\d))"),
          (Match _) => ",",
        );
  }
  if (value is num) {
    final int intValue = value.toInt();
    return intValue.toString().replaceAllMapped(
          RegExp(r"\B(?=(\d{3})+(?!\d))"),
          (Match _) => ",",
        );
  }
  final String raw = "$value".trim();
  if (raw.isEmpty) {
    return "0";
  }
  final String normalized = raw.replaceAll(",", "");
  final num? parsed = num.tryParse(normalized);
  if (parsed == null) return raw;
  return nzmFormatNumber(parsed);
}

String nzmFormatNumbersInText(String text) {
  if (text.trim().isEmpty) return text;
  return text.replaceAllMapped(
    RegExp(r"(?<![\d.])-?\d+(?:\.\d+)?(?![\d.])"),
    (Match m) => nzmFormatNumber(m.group(0) ?? "0"),
  );
}

class NzmBackground extends StatelessWidget {
  const NzmBackground({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[NzmTheme.bgDeep, NzmTheme.bgMid, Color(0xFF08111D)],
        ),
      ),
      child: child,
    );
  }
}

class NzmPanelCard extends StatelessWidget {
  const NzmPanelCard({
    required this.child,
    this.padding = const EdgeInsets.all(12),
    this.margin = const EdgeInsets.only(bottom: 10),
    super.key,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry margin;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: margin,
      child: Padding(padding: padding, child: child),
    );
  }
}

class NzmSectionTitle extends StatelessWidget {
  const NzmSectionTitle(this.text, {super.key, this.trailing});

  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: <Widget>[
          Container(
            width: 4,
            height: 18,
            margin: const EdgeInsets.only(right: 8),
            decoration: const BoxDecoration(
              color: NzmTheme.accent,
              borderRadius: BorderRadius.all(Radius.circular(99)),
            ),
          ),
          Expanded(
            child: Text(
              text,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

class NzmMetricCard extends StatelessWidget {
  const NzmMetricCard({
    required this.label,
    required this.value,
    this.width = 160,
    this.glass = false,
    super.key,
  });

  final String label;
  final String value;
  final double width;
  final bool glass;

  @override
  Widget build(BuildContext context) {
    final String displayValue = nzmFormatNumbersInText(value);
    if (glass) {
      return SizedBox(
        width: width,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 6, sigmaY: 6),
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xAA132843),
                border: Border.all(color: NzmTheme.line),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(label, style: Theme.of(context).textTheme.bodySmall),
                  const SizedBox(height: 8),
                  Text(
                    displayValue,
                    style: const TextStyle(
                      color: NzmTheme.text,
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }
    return SizedBox(
      width: width,
      child: NzmPanelCard(
        margin: EdgeInsets.zero,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(label, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 8),
            Text(
              displayValue,
              style: const TextStyle(
                color: NzmTheme.text,
                fontSize: 20,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class NzmStatusBar extends StatelessWidget {
  const NzmStatusBar({
    required this.message,
    this.showLoading = false,
    super.key,
  });

  final String message;
  final bool showLoading;

  @override
  Widget build(BuildContext context) {
    if (message.trim().isEmpty) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: NzmTheme.line.withValues(alpha: 0.4)),
        ),
        color: const Color(0xBB0B1626),
      ),
      child: Row(
        children: <Widget>[
          if (showLoading) ...<Widget>[
            const SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: Text(message, style: Theme.of(context).textTheme.bodySmall),
          ),
        ],
      ),
    );
  }
}

class NzmEmptyState extends StatelessWidget {
  const NzmEmptyState(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return NzmPanelCard(
      child: SizedBox(
        width: double.infinity,
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ),
    );
  }
}

class NzmFilterDropdown extends StatelessWidget {
  const NzmFilterDropdown({
    required this.label,
    required this.options,
    required this.value,
    required this.onChanged,
    this.width = 150,
    this.optionLabels = const <String, String>{},
    super.key,
  });

  final String label;
  final List<String> options;
  final String value;
  final ValueChanged<String> onChanged;
  final double width;
  final Map<String, String> optionLabels;

  @override
  Widget build(BuildContext context) {
    final String? current = options.contains(value) ? value : null;
    final TextStyle selectedStyle =
        Theme.of(context).textTheme.bodyMedium?.copyWith(fontSize: 11) ??
            const TextStyle(fontSize: 11);
    final TextStyle labelStyle =
        Theme.of(context).textTheme.bodySmall?.copyWith(
              fontSize: 11,
              height: 1.0,
            ) ??
            const TextStyle(fontSize: 11, height: 1.0);
    return SizedBox(
      width: width,
      child: DropdownButtonFormField<String>(
        initialValue: current,
        isExpanded: true,
        menuMaxHeight: 360,
        itemHeight: null,
        style: selectedStyle,
        dropdownColor: const Color(0xFF122339),
        decoration: InputDecoration(
          labelText: label,
          alignLabelWithHint: true,
          labelStyle: labelStyle,
          floatingLabelStyle: labelStyle,
          floatingLabelBehavior: FloatingLabelBehavior.always,
          contentPadding: const EdgeInsets.fromLTRB(10, 14, 8, 10),
          isDense: false,
          border: Theme.of(context).inputDecorationTheme.border,
        ),
        selectedItemBuilder: (BuildContext context) {
          return options.map((String e) {
            return Align(
              alignment: Alignment.centerLeft,
              child: Text(
                optionLabels[e] ?? e,
                style: selectedStyle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                softWrap: false,
              ),
            );
          }).toList();
        },
        items: options
            .map((String e) => DropdownMenuItem<String>(
                  value: e,
                  child: Text(
                    optionLabels[e] ?? e,
                    style: selectedStyle,
                    maxLines: 4,
                    softWrap: true,
                  ),
                ))
            .toList(),
        onChanged: (String? selected) {
          if (selected == null) return;
          onChanged(selected);
        },
      ),
    );
  }
}
