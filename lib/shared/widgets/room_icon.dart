import 'package:flutter/material.dart';

class OrexRoomIconChoice {
  const OrexRoomIconChoice({
    required this.key,
    required this.label,
    required this.icon,
  });

  final String key;
  final String label;
  final IconData icon;
}

const orexRoomIconChoices = <OrexRoomIconChoice>[
  OrexRoomIconChoice(
    key: 'chat',
    label: 'Чат',
    icon: Icons.forum,
  ),
  OrexRoomIconChoice(
    key: 'announce',
    label: 'Объявления',
    icon: Icons.campaign,
  ),
  OrexRoomIconChoice(
    key: 'help',
    label: 'Помощь',
    icon: Icons.support_agent,
  ),
  OrexRoomIconChoice(
    key: 'code',
    label: 'Код',
    icon: Icons.code,
  ),
  OrexRoomIconChoice(
    key: 'media',
    label: 'Медиа',
    icon: Icons.perm_media_outlined,
  ),
  OrexRoomIconChoice(
    key: 'lock',
    label: 'Закрытый',
    icon: Icons.lock_outline,
  ),
];

OrexRoomIconChoice orexRoomIconChoice(String key) {
  return orexRoomIconChoices.firstWhere(
    (choice) => choice.key == key,
    orElse: () => orexRoomIconChoices.first,
  );
}

IconData orexRoomIconData(String key) => orexRoomIconChoice(key).icon;
