// Минимальный прозрачный Service Worker (network-first)

// Установка - сразу активируем
self.addEventListener('install', event => {
  self.skipWaiting();
});

// Активация - сразу берём контроль
self.addEventListener('activate', event => {
  event.waitUntil(clients.claim());
});

// Обработка запросов - пропускаем всё в сеть
self.addEventListener('fetch', event => {
  event.respondWith(fetch(event.request));
});
