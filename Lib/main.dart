import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import 'package:intl/intl.dart';
import 'package:image_picker/image_picker.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:timezone/data/latest.dart' as tz_data;
import 'dart:io';

// ── COLORS ───────────────────────────────────────────────────────────────────
const kBg      = Color(0xFF0F1117);
const kSurface = Color(0xFF1A1D27);
const kCard    = Color(0xFF22263A);
const kGreen   = Color(0xFF4ADE80);
const kOrange  = Color(0xFFFF6B35);
const kYellow  = Color(0xFFFFD60A);
const kBlue    = Color(0xFF60A5FA);
const kRed     = Color(0xFFFF3B5C);
const kText1   = Color(0xFFF4F4F5);
const kText2   = Color(0xFF8B8FA8);
const kText3   = Color(0xFF4A4E6A);

// ── FOOD MODEL ───────────────────────────────────────────────────────────────
class FoodItem {
  final int?     id;
  final String   name;
  final DateTime expiryDate;
  final String   category;
  final String?  imagePath;

  FoodItem({this.id, required this.name, required this.expiryDate, required this.category, this.imagePath});

  int get daysLeft {
    final today = DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day);
    final exp   = DateTime(expiryDate.year, expiryDate.month, expiryDate.day);
    return exp.difference(today).inDays;
  }

  Color get color {
    if (daysLeft < 0)  return kRed;
    if (daysLeft == 0) return kOrange;
    if (daysLeft <= 3) return kYellow;
    if (daysLeft <= 7) return kBlue;
    return kGreen;
  }

  String get badge {
    if (daysLeft < 0)  return 'EXPIRED';
    if (daysLeft == 0) return 'TODAY';
    if (daysLeft <= 3) return 'SOON';
    if (daysLeft <= 7) return 'THIS WEEK';
    return 'FRESH';
  }

  String get timeLabel {
    if (daysLeft < 0)  return 'Expired ${-daysLeft}d ago';
    if (daysLeft == 0) return 'Expires today!';
    if (daysLeft == 1) return 'Expires tomorrow';
    if (daysLeft < 30) return 'Expires in $daysLeft days';
    return 'Expires in ${(daysLeft / 30).floor()} months';
  }

  String get emoji {
    switch (category) {
      case 'Dairy':      return '🥛';
      case 'Meat':       return '🥩';
      case 'Vegetables': return '🥦';
      case 'Fruits':     return '🍎';
      case 'Bakery':     return '🍞';
      case 'Beverages':  return '🥤';
      case 'Frozen':     return '🧊';
      case 'Snacks':     return '🍿';
      case 'Condiments': return '🫙';
      default:           return '🛒';
    }
  }

  Map<String, dynamic> toMap() => {
    'id': id, 'name': name,
    'expiry_date': expiryDate.toIso8601String(),
    'category': category, 'image_path': imagePath,
  };

  factory FoodItem.fromMap(Map<String, dynamic> m) => FoodItem(
    id: m['id'], name: m['name'],
    expiryDate: DateTime.parse(m['expiry_date']),
    category: m['category'], imagePath: m['image_path'],
  );

  FoodItem copyWith({int? id}) => FoodItem(
    id: id ?? this.id, name: name,
    expiryDate: expiryDate, category: category, imagePath: imagePath,
  );
}

// DATABASE
Database? _db;

Future<Database> getDb() async {
  if (_db != null) return _db!;
  _db = await openDatabase(
    p.join(await getDatabasesPath(), 'foodguard.db'),
    version: 1,
    onCreate: (db, _) => db.execute(
      'CREATE TABLE items(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, expiry_date TEXT, category TEXT, image_path TEXT)',
    ),
  );
  return _db!;
}

Future<List<FoodItem>> loadItems() async {
  final db   = await getDb();
  final rows = await db.query('items', orderBy: 'expiry_date ASC');
  return rows.map(FoodItem.fromMap).toList();
}

Future<int>  saveItem(FoodItem item)   async => (await getDb()).insert('items', item.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
Future<void> updateItem(FoodItem item) async => (await getDb()).update('items', item.toMap(), where: 'id=?', whereArgs: [item.id]);
Future<void> deleteItem(int id)        async => (await getDb()).delete('items', where: 'id=?', whereArgs: [id]);

// ── NOTIFICATIONS ────────────────────────────────────────────────────────────
final _notifs = FlutterLocalNotificationsPlugin();

Future<void> initNotifs() async {
  tz_data.initializeTimeZones();
  await _notifs.initialize(const InitializationSettings(
    android: AndroidInitializationSettings('@mipmap/ic_launcher'),
  ));
  await _notifs
      .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
      ?.requestNotificationsPermission();
}

Future<void> scheduleNotifs(FoodItem item) async {
  if (item.id == null) return;
  // Cancel old ones first
  for (int i = 0; i < 5; i++) await _notifs.cancel(item.id! * 10 + i);

  final labels = ['7 days', '3 days', '2 days', 'tomorrow', '2 hours'];
  final offsets = [
    Duration(days: 7), Duration(days: 3), Duration(days: 2),
    Duration(days: 1), Duration(hours: 2),
  ];

  for (int i = 0; i < offsets.length; i++) {
    final when = item.expiryDate.subtract(offsets[i]);
    if (when.isAfter(DateTime.now())) {
      await _notifs.zonedSchedule(
        item.id! * 10 + i,
        '${item.name} expires in ${labels[i]}!',
        'Use your ${item.name.toLowerCase()} before it goes bad.',
        tz.TZDateTime.from(when, tz.local),
        const NotificationDetails(android: AndroidNotificationDetails(
          'foodguard', 'FoodGuard Alerts',
          importance: Importance.high, priority: Priority.high,
        )),
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        uiLocalNotificationDateInterpretation:
        UILocalNotificationDateInterpretation.absoluteTime,
      );
    }
  }
}

Future<void> cancelNotifs(int id) async {
  for (int i = 0; i < 5; i++) await _notifs.cancel(id * 10 + i);
}

// ── OCR ──────────────────────────────────────────────────────────────────────
Future<DateTime?> scanExpiryDate(String imagePath) async {
  final recognizer = TextRecognizer();
  try {
    final result = await recognizer.processImage(InputImage.fromFilePath(imagePath));
    final text   = result.text.toUpperCase();

    final patterns = [
      RegExp(r'(?:BEST BY|EXP(?:IRY)?(?:\s*DATE)?|USE BY|BB|BBE)[:\s]*(\d{1,2}[\/\-\.]\d{1,2}[\/\-\.]\d{2,4})', caseSensitive: false),
      RegExp(r'(\d{1,2}[\/\-\.]\d{1,2}[\/\-\.]\d{2,4})'),
      RegExp(r'(\d{1,2}\s+(?:JAN|FEB|MAR|APR|MAY|JUN|JUL|AUG|SEP|OCT|NOV|DEC)\w*\s+\d{2,4})', caseSensitive: false),
    ];

    for (final pattern in patterns) {
      final match = pattern.firstMatch(text);
      if (match == null) continue;
      final dateStr = (match.group(1) ?? match.group(0)!).trim();
      for (final fmt in ['dd/MM/yyyy','MM/dd/yyyy','dd-MM-yyyy','dd.MM.yyyy','dd/MM/yy','dd MMM yyyy','MMM dd yyyy']) {
        try {
          final d = DateFormat(fmt).parseStrict(dateStr);
          final year = d.year < 100 ? d.year + 2000 : d.year;
          if (year >= 2020 && year <= 2040) return DateTime(year, d.month, d.day);
        } catch (_) {}
      }
    }
  } finally {
    recognizer.close();
  }
  return null;
}

// ── MAIN ─────────────────────────────────────────────────────────────────────
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initNotifs();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
  ));
  runApp(const MaterialApp(
    title: 'FoodGuard',
    debugShowCheckedModeBanner: false,
    home: HomeScreen(),
  ));
}

// ── HOME SCREEN ───────────────────────────────────────────────────────────────
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<FoodItem> items = [];
  bool loading = true;

  @override
  void initState() { super.initState(); refresh(); }

  Future<void> refresh() async {
    setState(() => loading = true);
    final all = await loadItems();
    all.sort((a, b) => a.daysLeft.compareTo(b.daysLeft));
    setState(() { items = all; loading = false; });
  }

  Future<void> goAdd([FoodItem? existing]) async {
    final result = await Navigator.push<FoodItem>(
      context, MaterialPageRoute(builder: (_) => AddScreen(existing: existing)),
    );
    if (result == null) return;
    if (existing == null) {
      final id = await saveItem(result);
      await scheduleNotifs(result.copyWith(id: id));
    } else {
      await updateItem(result);
      await scheduleNotifs(result);
    }
    refresh();
  }

  Future<void> remove(FoodItem item) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: kCard,
        title: const Text('Remove item?', style: TextStyle(color: kText1)),
        content: Text('Remove "${item.name}" from your list?', style: const TextStyle(color: kText2)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel', style: TextStyle(color: kText2))),
          TextButton(onPressed: () => Navigator.pop(context, true),  child: const Text('Remove', style: TextStyle(color: kRed))),
        ],
      ),
    );
    if (ok == true) {
      await deleteItem(item.id!);
      await cancelNotifs(item.id!);
      refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    final urgent = items.where((i) => i.daysLeft <= 0).length;

    return Scaffold(
      backgroundColor: kBg,
      body: SafeArea(child: Column(children: [

        // ── Header
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
          child: Row(children: [
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('FoodGuard', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800, color: kText1, letterSpacing: -1)),
              Text(DateFormat('EEE, MMM d').format(DateTime.now()), style: const TextStyle(fontSize: 13, color: kText2)),
            ]),
            const Spacer(),
            if (urgent > 0)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: kRed.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: kRed.withOpacity(0.4)),
                ),
                child: Row(children: [
                  const Icon(Icons.warning_rounded, color: kRed, size: 15),
                  const SizedBox(width: 4),
                  Text('$urgent expired', style: const TextStyle(color: kRed, fontSize: 12, fontWeight: FontWeight.w600)),
                ]),
              ),
          ]),
        ),

        // ── Stats row
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
          child: Row(children: [
            _stat('${items.length}',                                                                        'Total',     kText2),
            const SizedBox(width: 8),
            _stat('${items.where((i) => i.daysLeft < 0).length}',                                          'Expired',   kRed),
            const SizedBox(width: 8),
            _stat('${items.where((i) => i.daysLeft >= 0 && i.daysLeft <= 7).length}',                      'This Week', kYellow),
            const SizedBox(width: 8),
            _stat('${items.where((i) => i.daysLeft > 7).length}',                                          'Fresh',     kGreen),
          ]),
        ),

        // List
        Expanded(
          child: loading
              ? const Center(child: CircularProgressIndicator(color: kGreen))
              : items.isEmpty
              ? const Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Text('🛒', style: TextStyle(fontSize: 56)),
            SizedBox(height: 12),
            Text('Nothing tracked yet', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: kText1)),
            SizedBox(height: 6),
            Text('Tap + to add your first item', style: TextStyle(color: kText2)),
          ]))
              : RefreshIndicator(
            color: kGreen, backgroundColor: kCard, onRefresh: refresh,
            child: ListView.builder(
              padding: const EdgeInsets.only(top: 12, bottom: 100),
              itemCount: items.length,
              itemBuilder: (_, i) => _FoodCard(item: items[i], onEdit: () => goAdd(items[i]), onDelete: () => remove(items[i])),
            ),
          ),
        ),
      ])),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => goAdd(),
        backgroundColor: kGreen,
        foregroundColor: Colors.black,
        icon: const Icon(Icons.add_rounded),
        label: const Text('Add Food', style: TextStyle(fontWeight: FontWeight.w700)),
      ),
    );
  }

  Widget _stat(String val, String label, Color color) => Expanded(
    child: Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        color: color.withOpacity(0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.2)),
      ),
      child: Column(children: [
        Text(val,   style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: color)),
        Text(label, style: const TextStyle(fontSize: 10, color: kText3, fontWeight: FontWeight.w500)),
      ]),
    ),
  );
}

// ── FOOD CARD ─────────────────────────────────────────────────────────────────
class _FoodCard extends StatelessWidget {
  final FoodItem    item;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  const _FoodCard({required this.item, required this.onEdit, required this.onDelete});

  @override
  Widget build(BuildContext context) {
    final color    = item.color;
    final expired  = item.daysLeft < 0;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
      child: Container(
        decoration: BoxDecoration(
          color: kSurface,
          borderRadius: BorderRadius.circular(14),
          border: item.daysLeft <= 3 ? Border.all(color: color.withOpacity(0.35)) : null,
        ),
        child: Row(children: [
          // Coloured left bar
          Container(width: 4, height: 72, decoration: BoxDecoration(
            color: color, borderRadius: const BorderRadius.horizontal(left: Radius.circular(14)),
          )),
          const SizedBox(width: 12),
          // Emoji icon
          Container(
            width: 44, height: 44,
            decoration: BoxDecoration(color: color.withOpacity(0.1), borderRadius: BorderRadius.circular(10)),
            child: Center(child: Text(item.emoji, style: const TextStyle(fontSize: 22))),
          ),
          const SizedBox(width: 12),
          // Text
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(item.name,
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: expired ? kText2 : kText1,
                  decoration: expired ? TextDecoration.lineThrough : null),
              maxLines: 1, overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 3),
            Row(children: [
              Icon(Icons.schedule_rounded, size: 12, color: color),
              const SizedBox(width: 4),
              Text(item.timeLabel, style: TextStyle(fontSize: 12, color: color, fontWeight: FontWeight.w500)),
            ]),
            Text('${DateFormat('MMM d, yyyy').format(item.expiryDate)}  ·  ${item.category}',
                style: const TextStyle(fontSize: 11, color: kText3)),
          ])),
          // Badge
          Container(
            margin: const EdgeInsets.only(right: 8),
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
            decoration: BoxDecoration(color: color.withOpacity(0.15), borderRadius: BorderRadius.circular(6)),
            child: Text(item.badge, style: TextStyle(fontSize: 9, fontWeight: FontWeight.w700, color: color, letterSpacing: 0.5)),
          ),
          // Actions
          Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            IconButton(icon: const Icon(Icons.edit_rounded, size: 18, color: kText2),      onPressed: onEdit,   padding: EdgeInsets.zero),
            IconButton(icon: const Icon(Icons.delete_rounded, size: 18, color: kText3), onPressed: onDelete, padding: EdgeInsets.zero),
          ]),
          const SizedBox(width: 4),
        ]),
      ),
    );
  }
}

// ADD / EDIT SCREEN
class AddScreen extends StatefulWidget {
  final FoodItem? existing;
  const AddScreen({super.key, this.existing});
  @override
  State<AddScreen> createState() => _AddScreenState();
}

class _AddScreenState extends State<AddScreen> {
  final _formKey  = GlobalKey<FormState>();
  final _nameCtrl = TextEditingController();
  final _picker   = ImagePicker();

  DateTime? _date;
  String    _category = 'Other';
  String?   _imagePath;
  bool      _scanning = false;

  final _categories = ['Fruits','Vegetables','Dairy','Meat','Bakery','Beverages','Frozen','Snacks','Condiments','Other'];

  @override
  void initState() {
    super.initState();
    if (widget.existing != null) {
      _nameCtrl.text = widget.existing!.name;
      _date          = widget.existing!.expiryDate;
      _category      = widget.existing!.category;
      _imagePath     = widget.existing!.imagePath;
    }
  }

  @override
  void dispose() { _nameCtrl.dispose(); super.dispose(); }

  Future<void> _pickImage(ImageSource src) async {
    final picked = await _picker.pickImage(source: src, imageQuality: 85, maxWidth: 1600);
    if (picked == null) return;
    setState(() { _imagePath = picked.path; _scanning = true; });
    final date = await scanExpiryDate(picked.path);
    setState(() { _scanning = false; if (date != null) _date = date; });
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      backgroundColor: kCard,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      content: Row(children: [
        Icon(date != null ? Icons.check_circle : Icons.warning_amber_rounded,
            color: date != null ? kGreen : kYellow),
        const SizedBox(width: 8),
        Text(
          date != null ? 'Date found: ${DateFormat('MMM d, yyyy').format(date)}' : 'No date found — enter manually',
          style: const TextStyle(color: kText1),
        ),
      ]),
    ));
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date ?? DateTime.now().add(const Duration(days: 7)),
      firstDate: DateTime.now().subtract(const Duration(days: 365)),
      lastDate:  DateTime.now().add(const Duration(days: 3650)),
      builder: (ctx, child) => Theme(
        data: Theme.of(ctx).copyWith(
          colorScheme: const ColorScheme.dark(primary: kGreen, onPrimary: Colors.black, surface: kCard, onSurface: kText1),
        ),
        child: child!,
      ),
    );
    if (picked != null) setState(() => _date = picked);
  }

  void _save() {
    if (!_formKey.currentState!.validate()) return;
    if (_date == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select an expiry date'), backgroundColor: kOrange),
      );
      return;
    }
    Navigator.pop(context, FoodItem(
      id: widget.existing?.id,
      name: _nameCtrl.text.trim(),
      expiryDate: _date!,
      category: _category,
      imagePath: _imagePath,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kBg, elevation: 0,
        leading: IconButton(icon: const Icon(Icons.arrow_back_ios_rounded, color: kText1), onPressed: () => Navigator.pop(context)),
        title: Text(widget.existing != null ? 'Edit Item' : 'Add Food',
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: kText1)),
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [

            // ── Camera buttons
            _sectionLabel('Photo & Auto-Scan'),
            const SizedBox(height: 8),
            if (_imagePath != null) ...[
              Stack(children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.file(File(_imagePath!), width: double.infinity, height: 160, fit: BoxFit.cover),
                ),
                if (_scanning)
                  Positioned.fill(child: Container(
                    decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(12)),
                    child: const Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                      CircularProgressIndicator(color: kGreen),
                      SizedBox(height: 10),
                      Text('Scanning for date...', style: TextStyle(color: kText1)),
                    ]),
                  )),
                Positioned(top: 8, right: 8, child: GestureDetector(
                  onTap: () => setState(() => _imagePath = null),
                  child: Container(
                    padding: const EdgeInsets.all(5),
                    decoration: const BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
                    child: const Icon(Icons.close_rounded, color: Colors.white, size: 16),
                  ),
                )),
              ]),
            ] else ...[
              Row(children: [
                Expanded(child: _camBtn(Icons.camera_alt_rounded, 'Camera',  kGreen, () => _pickImage(ImageSource.camera))),
                const SizedBox(width: 12),
                Expanded(child: _camBtn(Icons.photo_library_rounded, 'Gallery', kBlue,  () => _pickImage(ImageSource.gallery))),
              ]),
            ],
            const SizedBox(height: 20),

            // ── Name
            _sectionLabel('Food Name'),
            const SizedBox(height: 8),
            TextFormField(
              controller: _nameCtrl,
              textCapitalization: TextCapitalization.words,
              style: const TextStyle(color: kText1),
              decoration: InputDecoration(
                filled: true, fillColor: kCard,
                hintText: 'e.g. Whole Milk, Cheddar...',
                hintStyle: const TextStyle(color: kText3),
                prefixIcon: const Icon(Icons.fastfood_rounded, color: kText2),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: kGreen, width: 1.5)),
              ),
              validator: (v) => (v == null || v.trim().isEmpty) ? 'Enter a name' : null,
            ),
            const SizedBox(height: 20),

            // ── Date
            _sectionLabel('Expiry Date'),
            const SizedBox(height: 8),
            GestureDetector(
              onTap: _pickDate,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
                decoration: BoxDecoration(
                  color: kCard, borderRadius: BorderRadius.circular(12),
                  border: _date != null ? Border.all(color: kGreen.withOpacity(0.5)) : null,
                ),
                child: Row(children: [
                  Icon(Icons.calendar_today_rounded, color: _date != null ? kGreen : kText2, size: 20),
                  const SizedBox(width: 12),
                  Text(
                    _date != null ? DateFormat('EEE, MMM d, yyyy').format(_date!) : 'Tap to select date',
                    style: TextStyle(fontSize: 15, color: _date != null ? kText1 : kText3,
                        fontWeight: _date != null ? FontWeight.w500 : FontWeight.w400),
                  ),
                  const Spacer(),
                  const Icon(Icons.chevron_right_rounded, color: kText3),
                ]),
              ),
            ),
            const SizedBox(height: 20),

            // ── Category
            _sectionLabel('Category'),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8, runSpacing: 8,
              children: _categories.map((cat) {
                final sel = _category == cat;
                return GestureDetector(
                  onTap: () => setState(() => _category = cat),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: sel ? kGreen.withOpacity(0.12) : kCard,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: sel ? kGreen : const Color(0xFF2A2E42), width: sel ? 1.5 : 1),
                    ),
                    child: Text(cat, style: TextStyle(
                      color: sel ? kGreen : kText2,
                      fontWeight: sel ? FontWeight.w600 : FontWeight.w400,
                      fontSize: 13,
                    )),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 32),

            // ── Save button
            SizedBox(
              width: double.infinity, height: 50,
              child: ElevatedButton(
                onPressed: _save,
                style: ElevatedButton.styleFrom(
                  backgroundColor: kGreen, foregroundColor: Colors.black,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: Text(widget.existing != null ? 'Save Changes' : 'Add to Tracker',
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              ),
            ),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }

  Widget _sectionLabel(String text) => Text(text,
      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: kText2, letterSpacing: 0.5));

  Widget _camBtn(IconData icon, String label, Color color, VoidCallback onTap) => GestureDetector(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(vertical: 16),
      decoration: BoxDecoration(
        color: color.withOpacity(0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Column(children: [
        Icon(icon, color: color, size: 26),
        const SizedBox(height: 5),
        Text(label, style: TextStyle(color: color, fontWeight: FontWeight.w600, fontSize: 13)),
      ]),
    ),
  );
}