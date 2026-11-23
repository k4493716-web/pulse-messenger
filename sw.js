const CACHE_NAME = 'pulse-v1';
const urlsToCache = [
  '/',
  '/index.html',
  '/icon.svg'
];

// Установка Service Worker
self.addEventListener('install', event => {
  event.waitUntil(
    caches.open(CACHE_NAME)
      .then(cache => {
        console.log('Opened cache');
        return cache.addAll(urlsToCache.map(url => new Request(url, {cache: 'reload'})));
      })
      .catch(err => {
        console.log('Cache addAll error:', err);
      })
  );
  self.skipWaiting();
});

// Активация Service Worker
self.addEventListener('activate', event => {
  event.waitUntil(
    caches.keys().then(cacheNames => {
      return Promise.all(
        cacheNames.map(cacheName => {
          if (cacheName !== CACHE_NAME) {
            console.log('Deleting old cache:', cacheName);
            return caches.delete(cacheName);
          }
        })
      );
    })
  );
  self.clients.claim();
});

// Обработка запросов
self.addEventListener('fetch', event => {
  // Игнорируем запросы к Supabase и внешним ресурсам
  if (event.request.url.includes('supabase.co') ||
      event.request.url.includes('cdn.jsdelivr.net') ||
      event.request.method !== 'GET') {
    return;
  }

  event.respondWith(
    caches.match(event.request)
      .then(response => {
        // Возвращаем закешированный ответ, если есть
        if (response) {
          return response;
        }
        // Иначе делаем сетевой запрос
        return fetch(event.request).then(response => {
          // Кешируем только успешные GET-запросы
          if (!response || response.status !== 200 || response.type === 'error') {
            return response;
          }

          const responseToCache = response.clone();
          caches.open(CACHE_NAME)
            .then(cache => {
              cache.put(event.request, responseToCache);
            });

          return response;
        });
      })
      .catch(() => {
        // Возвращаем офлайн-страницу, если есть
        return caches.match('/index.html');
      })
  );
});
