import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/plate_result_stabilizer.dart';

/// Bottom sheet displaying detection history log
class PlateHistorySheet extends StatelessWidget {
  final List<PlateHistoryEntry> history;
  final VoidCallback? onClear;

  const PlateHistorySheet({
    super.key,
    required this.history,
    this.onClear,
  });

  static void show(
      BuildContext context, {
        required List<PlateHistoryEntry> history,
        VoidCallback? onClear,
      }) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => PlateHistorySheet(
        history: history,
        onClear: onClear,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.5,
      minChildSize: 0.3,
      maxChildSize: 0.85,
      builder: (context, scrollController) {
        return Container(
          decoration: const BoxDecoration(
            color: Color(0xFF1E1E1E),
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: Column(
            children: [
              // Handle bar
              Padding(
                padding: const EdgeInsets.only(top: 12, bottom: 8),
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.grey.shade600,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),

              // Header
              Padding(
                padding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  children: [
                    const Icon(Icons.history, color: Colors.white70, size: 20),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        'Detection History',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    // Count badge
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.blue.withOpacity(0.2),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        '${history.length}',
                        style: TextStyle(
                          color: Colors.blue.shade300,
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    if (history.isNotEmpty) ...[
                      const SizedBox(width: 8),
                      IconButton(
                        icon: Icon(Icons.delete_outline,
                            color: Colors.red.shade300, size: 20),
                        onPressed: () {
                          onClear?.call();
                          Navigator.pop(context);
                        },
                        tooltip: 'Clear history',
                        visualDensity: VisualDensity.compact,
                      ),
                    ],
                  ],
                ),
              ),

              const Divider(color: Colors.white12, height: 1),

              // List
              Expanded(
                child: history.isEmpty
                    ? _buildEmptyState()
                    : ListView.builder(
                  controller: scrollController,
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: history.length,
                  itemBuilder: (context, index) {
                    // Show newest first
                    final entry =
                    history[history.length - 1 - index];
                    return _PlateHistoryTile(
                      entry: entry,
                      index: index + 1,
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.search_off, size: 48, color: Colors.grey.shade700),
          const SizedBox(height: 16),
          Text(
            'No plates detected yet',
            style: TextStyle(
              color: Colors.grey.shade500,
              fontSize: 16,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Confirmed plates will appear here',
            style: TextStyle(
              color: Colors.grey.shade600,
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }
}

class _PlateHistoryTile extends StatelessWidget {
  final PlateHistoryEntry entry;
  final int index;

  const _PlateHistoryTile({
    required this.entry,
    required this.index,
  });

  @override
  Widget build(BuildContext context) {
    final timeStr = _formatTime(entry.timestamp);
    final confPercent = (entry.confidence * 100).toInt();

    return InkWell(
      onTap: () => _copyToClipboard(context, entry.fullPlate),
      onLongPress: () => _copyToClipboard(context, entry.fullPlate),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.05),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.white.withOpacity(0.08)),
        ),
        child: Row(
          children: [
            // Index number
            Container(
              width: 28,
              height: 28,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: Colors.green.withOpacity(0.15),
                shape: BoxShape.circle,
              ),
              child: Text(
                '$index',
                style: TextStyle(
                  color: Colors.green.shade300,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),

            const SizedBox(width: 12),

            // Plate info
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Plate text
                  Text(
                    entry.fullPlate,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      fontFamily: 'monospace',
                      letterSpacing: 2,
                    ),
                  ),
                  const SizedBox(height: 4),

                  // Metadata row
                  Row(
                    children: [
                      // Time
                      Icon(Icons.access_time,
                          size: 12, color: Colors.grey.shade500),
                      const SizedBox(width: 4),
                      Text(
                        timeStr,
                        style: TextStyle(
                          color: Colors.grey.shade500,
                          fontSize: 11,
                        ),
                      ),

                      const SizedBox(width: 12),

                      // Code/Number
                      if (entry.code.isNotEmpty) ...[
                        Text(
                          'Code: ${entry.code}',
                          style: TextStyle(
                            color: Colors.grey.shade500,
                            fontSize: 11,
                          ),
                        ),
                        const SizedBox(width: 8),
                      ],

                      // Frames seen
                      Icon(Icons.visibility,
                          size: 12, color: Colors.grey.shade500),
                      const SizedBox(width: 4),
                      Text(
                        '${entry.totalFramesSeen}f',
                        style: TextStyle(
                          color: Colors.grey.shade500,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            // Confidence
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: _getConfidenceColor(confPercent).withOpacity(0.15),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                '$confPercent%',
                style: TextStyle(
                  color: _getConfidenceColor(confPercent),
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  fontFamily: 'monospace',
                ),
              ),
            ),

            const SizedBox(width: 8),

            // Copy icon hint
            Icon(Icons.copy, size: 14, color: Colors.grey.shade700),
          ],
        ),
      ),
    );
  }

  Color _getConfidenceColor(int percent) {
    if (percent >= 80) return Colors.green.shade300;
    if (percent >= 60) return Colors.orange.shade300;
    return Colors.red.shade300;
  }

  String _formatTime(DateTime time) {
    final h = time.hour.toString().padLeft(2, '0');
    final m = time.minute.toString().padLeft(2, '0');
    final s = time.second.toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  void _copyToClipboard(BuildContext context, String text) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Copied: $text'),
        duration: const Duration(seconds: 1),
        behavior: SnackBarBehavior.floating,
        backgroundColor: Colors.green.shade700,
      ),
    );
  }
}