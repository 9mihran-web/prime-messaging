# Prime Messaging Video Calling Roadmap

## Цель
Стабильные 1:1 интернет-видеозвонки поверх текущего аудио-стека (PushKit + CallKit + WebRTC), без регрессий в lockscreen/system answer.

## Этап 1 (сделано сейчас): Media foundation
- Добавить в WebRTC-сессию видео-трек (подготовленный, но выключенный по умолчанию).
- Добавить управление локальной камерой: start/stop capture, логи устройства/формата/FPS.
- Добавить `OfferToReceiveVideo` в SDP offer/answer constraints.
- Привязать кнопку Video к реальному включению/выключению локального видео-трека.
- Добавить проверку camera permission перед включением видео.

## Этап 2: UI видео-потока
- Показ `remote` видео в `InternetCallView`.
- Плавающее окно `local preview` (PiP-стиль).
- Фоллбэк на аватар, если remote video отсутствует.
- Корректная работа поворота экрана и safe area.

## Этап 3: Стабильность системных сценариев
- Ответ с lockscreen/Dynamic Island: стабильный старт audio+video.
- Переход background <-> foreground без потери media pipeline.
- Восстановление после route change (Bluetooth/receiver/speaker).
- Идемпотентная обработка повторных call events.

## Этап 4: Сетевое качество
- Адаптивные профили capture (low/medium/high).
- Ограничение битрейта для cellular.
- Проверка TURN relay path для видео.
- Обработка деградации: fallback video->audio при проблемной сети.

## Этап 5: Бета-готовность
- Матрица тестов: iOS 16/17/18+, разные устройства.
- Тесты сценариев: incoming/outgoing, lockscreen, force-quit, weak network.
- Финальные метрики/логи для диагностики.

## Критерии готовности MVP видео
- Два устройства видят друг друга в звонке.
- Audio не ломается при включении/выключении видео.
- Кнопка Video реально управляет камерой и отправкой видео.
- Нет зависаний при ответе через системный экран звонка.
