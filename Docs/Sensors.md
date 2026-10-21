# Датчики и автосчёт

Проверено по спецификациям Apple 21 октября 2026 года. Наличие датчика и поддержка конкретного приложения — разные вещи.

## Датчик приближения

Обычный датчик приближения сообщает только состояние «близко / далеко». Публичный API не выдаёт расстояние в сантиметрах и не позволяет задать дистанцию срабатывания. Когда датчик срабатывает, iOS может погасить экран. Если лицо не подходит достаточно близко, движение не будет обнаружено. Точный универсальный порог Apple не публикует; обещать определённую дальность нельзя. [UIDevice](https://developer.apple.com/documentation/uikit/uidevice/isproximitymonitoringenabled), [proximityState](https://developer.apple.com/documentation/uikit/uidevice/proximitystate), [поведение экрана](https://developer.apple.com/documentation/uikit/uiapplication/proximitysensingenabled).

Датчик есть во всех поколениях iPhone:

| Семейство | Модели |
| --- | --- |
| Первые поколения | iPhone, 3G, 3GS, 4, 4s, 5, 5c, 5s |
| 6 | 6, 6 Plus, 6s, 6s Plus |
| 7 и 8 | 7, 7 Plus, 8, 8 Plus |
| X | X, XR, XS, XS Max |
| 11 | 11, 11 Pro, 11 Pro Max |
| 12 | 12 mini, 12, 12 Pro, 12 Pro Max |
| 13 | 13 mini, 13, 13 Pro, 13 Pro Max |
| 14 | 14, 14 Plus, 14 Pro, 14 Pro Max |
| 15 | 15, 15 Plus, 15 Pro, 15 Pro Max |
| 16 | 16e, 16, 16 Plus, 16 Pro, 16 Pro Max |
| 17 и Air | 17e, 17, 17 Pro, 17 Pro Max, iPhone Air |
| 18 Pro | 18 Pro, 18 Pro Max |
| SE | SE 1-го, 2-го и 3-го поколений |
| Duo | Заявлен Apple; прямой тест pushx не выполнен |

Источники: [современные модели Apple](https://www.apple.com/iphone/compare/), [первый iPhone](https://www.apple.com/uk/newsroom/2007/01/09Apple-Reinvents-the-Phone-with-iPhone/), [3GS](https://support.apple.com/en-by/112307), [4s](https://support.apple.com/en-gb/112004), [5c](https://support.apple.com/en-kw/111917), [5s](https://support.apple.com/en-am/111973), [6](https://support.apple.com/en-us/111954), [SE](https://support.apple.com/en-gb/112005), [Duo](https://www.apple.com/iphone-duo/specs/).

**iPad с таким датчиком нет:** ни обычных iPad, ни iPad mini, iPad Air или iPad Pro любого поколения. LiDAR у некоторых iPad Pro — другой компонент, расположенный сзади. [Сравнение iPad](https://www.apple.com/ipad/compare/), [iPad Pro M5](https://support.apple.com/en-euro/125406).

## Что использует pushx

Выбранный пользователем пример pushr описывает определение расстояния до лица через TrueDepth. Это подтверждено [политикой самого разработчика](https://push.joogps.com/privacy). Запись видео у pushr — отдельная функция, упомянутая в истории обновлений [App Store](https://apps.apple.com/us/app/pushr-push-up-workouts/id1587610077).

pushx использует `ARFaceTrackingConfiguration` и положение `ARFaceAnchor` относительно камеры. На экране отображается счётчик без камеры; видео, кадры, геометрия лица и расстояния не сохраняются и не отправляются. Лицо не используется для установления личности. Приложение запрашивает доступ к камере, поэтому системный индикатор камеры остаётся видимым.

Современный ARKit поддерживает отслеживание лица и на устройствах с Apple Neural Engine без TrueDepth. При запуске pushx проверяет `ARFaceTrackingConfiguration.isSupported`; неподдерживаемое устройство не получает вымышленный счёт. Отдельно требуется физическая проверка качества подсчёта на каждой группе камер. Наличие ARKit не гарантирует одинаковую точность с аппаратным TrueDepth. [ARKit Face Tracking](https://developer.apple.com/documentation/arkit/arfacetrackingconfiguration/).

Минимальная версия pushx — iOS / iPadOS 17. Исторические iPhone в таблице перечислены для ответа о датчике и не означают возможность установки приложения.
