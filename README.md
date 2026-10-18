# BarGrup

macOS menü çubuğundaki uygulama simgelerini **renkli gruplar** altında toplayan küçük bir yardımcı.
Gruptaki öğeler menü çubuğundan gizlenir. Grubun simgesine tıklayınca öğeler bir panelde açılır, birine tıklamak o öğenin menüsünü açar.

*A small macOS menu bar organizer: groups other apps' menu bar items under colored icons and hides them until you need them.*

## Özellikler

- Her grup menü çubuğunda kendi **renkli simgesiyle** durur (renk ve SF Symbol seçilebilir).
- Ayarlar penceresinden **grup ekleme/silme**, gruba öğe ekleme/çıkarma ve sürükleyerek sıralama.
- Gruplar `~/Library/Application Support/BarGrup/config.json` dosyasında saklanır ve **açılışta geri yüklenir**.
- **Öğeleri yerleştir:** gruptaki öğeleri gizli bölüme, diğerlerini görünür bölüme otomatik taşır (⌘-sürükleme).
- **‹ ›** düğmesi gizli öğelerin hepsini geçici olarak gösterir. Sağ tık: Ayarlar, Yerleştir, Çıkış.
- Ekran kaydı izni gerekmez. Yalnızca **Erişilebilirlik** izni ister.

## Kurulum (hazır sürüm)

1. [Releases](../../releases) sayfasından `BarGrup.zip` dosyasını indirip açın ve `BarGrup.app`'i **Uygulamalar** klasörüne taşıyın.
2. Uygulama Apple tarafından onaylanmış (notarize) bir geliştirici imzası taşımadığı için macOS ilk açılışta engeller:
   uygulamayı bir kez açmayı deneyin, sonra **Sistem Ayarları → Gizlilik ve Güvenlik → "Yine de Aç"** deyin.
3. **Sistem Ayarları → Gizlilik ve Güvenlik → Erişilebilirlik** bölümünde BarGrup'a izin verin.
   Bu izin menü çubuğu öğelerini bulmak, açmak ve taşımak için gereklidir.

Gereksinim: macOS 14 (Sonoma) veya üstü, Apple Silicon ya da Intel.

## Kullanım

1. Menü çubuğundaki **‹** düğmesine sağ tıklayıp **Ayarlar…**'ı açın.
2. **+** ile grup ekleyin, ad, renk ve simge seçin.
3. Sağdaki "Menü çubuğundaki öğeler" listesinden **+** ile öğeleri gruba ekleyin.
4. Ayarlar penceresini kapatın. BarGrup öğeleri otomatik olarak yerleştirir.
   Yerleştirme sırasında fare imleci birkaç saniye kendi kendine hareket eder; fareyi oynatmayın.

Menü çubuğu düzeni: `[gizli öğeler][⁄ ayraç][grup simgeleri][görünür öğeler][‹ ›]`.
Ayracın solundaki her şey gizlenir. Öğeleri ⌘ tuşuna basılı tutarak elle de sürükleyebilirsiniz.

## Kaynaktan derleme

Xcode 15+ veya Xcode komut satırı araçları gerekir.

```bash
git clone https://github.com/mhfindik/BarGrup.git
cd BarGrup
./build.sh                # build/BarGrup.app
UNIVERSAL=1 ./build.sh    # Apple Silicon + Intel
```

Kendi derlediğiniz sürüm Gatekeeper uyarısı vermez. `build.sh` imzanın kimlik gereksinimini paket kimliğine sabitler,
bu sayede verdiğiniz Erişilebilirlik izni yeniden derlemelerde korunur.

## Nasıl çalışır?

- Öğeler, her uygulamanın Erişilebilirlik ağacındaki `AXExtrasMenuBar` üzerinden bulunur ve `AXPress` ile açılır.
- Gizleme için bir ayraç `NSStatusItem` kullanılır: gizliyken genişleyerek solundaki öğeleri ekran dışına iter.
- Öğeleri taşımak için sentetik ⌘-sürükleme olayları gönderilir.
- Hata ayıklama günlüğü: `~/Library/Application Support/BarGrup/debug.log`.

## Bilinen sınırlamalar

- Saat ve Denetim Merkezi gibi bazı sistem öğelerini macOS taşıtmaz.
- Çentikli MacBook'larda menü çubuğu çok doluysa, gizli bölüm geçici olarak gösterildiğinde bazı öğeler çentiğin arkasında kalabilir.
  Bu öğeler yine de gruptaki panelden açılabilir.
