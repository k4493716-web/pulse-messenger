-- ============================================
-- PULSE MESSENGER - SUPABASE SETUP SCRIPT
-- ============================================
-- Этот скрипт создаёт все необходимые таблицы, Storage бакеты и RLS политики
-- Выполните его в SQL Editor на https://supabase.com/dashboard/project/YOUR_PROJECT/sql

-- ============================================
-- 1. ВКЛЮЧАЕМ РАСШИРЕНИЯ
-- ============================================

-- Расширение для UUID (обычно уже включено)
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- ============================================
-- 2. ТАБЛИЦА PROFILES (ПРОФИЛИ ПОЛЬЗОВАТЕЛЕЙ)
-- ============================================

-- Создаём таблицу профилей
CREATE TABLE IF NOT EXISTS public.profiles (
    id UUID REFERENCES auth.users(id) ON DELETE CASCADE PRIMARY KEY,
    username TEXT UNIQUE,
    display_name TEXT,
    bio TEXT,
    avatar_url TEXT,
    banner_url TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Индексы для быстрого поиска
CREATE INDEX IF NOT EXISTS idx_profiles_username ON public.profiles(username);
CREATE INDEX IF NOT EXISTS idx_profiles_created_at ON public.profiles(created_at DESC);

-- Добавляем проверку на формат username
ALTER TABLE public.profiles
ADD CONSTRAINT username_format CHECK (username ~* '^[a-z0-9_]{5,32}$');

-- Добавляем ограничение на длину bio
ALTER TABLE public.profiles
ADD CONSTRAINT bio_length CHECK (char_length(bio) <= 160);

-- ============================================
-- 3. ТАБЛИЦА MESSAGES (СООБЩЕНИЯ)
-- ============================================

-- Создаём таблицу сообщений
CREATE TABLE IF NOT EXISTS public.messages (
    id UUID DEFAULT uuid_generate_v4() PRIMARY KEY,
    sender_id UUID REFERENCES public.profiles(id) ON DELETE CASCADE NOT NULL,
    receiver_id UUID REFERENCES public.profiles(id) ON DELETE CASCADE NOT NULL,
    content TEXT,
    media_url TEXT,
    media_type TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Индексы для быстрой выборки сообщений
CREATE INDEX IF NOT EXISTS idx_messages_sender ON public.messages(sender_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_messages_receiver ON public.messages(receiver_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_messages_conversation ON public.messages(sender_id, receiver_id, created_at DESC);

-- Добавляем проверку на допустимые типы медиа
ALTER TABLE public.messages
ADD CONSTRAINT media_type_check CHECK (media_type IN ('image', 'video', 'audio') OR media_type IS NULL);

-- ============================================
-- 4. ФУНКЦИЯ ДЛЯ АВТОМАТИЧЕСКОГО СОЗДАНИЯ ПРОФИЛЯ
-- ============================================

-- Эта функция автоматически создаёт запись в profiles при регистрации нового пользователя
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO public.profiles (id, created_at)
    VALUES (NEW.id, NOW());
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Триггер на создание нового пользователя
DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
    AFTER INSERT ON auth.users
    FOR EACH ROW
    EXECUTE FUNCTION public.handle_new_user();

-- ============================================
-- 5. RLS ПОЛИТИКИ ДЛЯ PROFILES
-- ============================================

-- Включаем Row Level Security для таблицы profiles
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;

-- Политика: Любой авторизованный пользователь может читать профили
CREATE POLICY "Profiles are viewable by authenticated users"
ON public.profiles
FOR SELECT
TO authenticated
USING (true);

-- Политика: Пользователь может обновлять только свой профиль
CREATE POLICY "Users can update their own profile"
ON public.profiles
FOR UPDATE
TO authenticated
USING (auth.uid() = id)
WITH CHECK (auth.uid() = id);

-- Политика: Пользователь может вставлять только свой профиль (для триггера)
CREATE POLICY "Users can insert their own profile"
ON public.profiles
FOR INSERT
TO authenticated
WITH CHECK (auth.uid() = id);

-- ============================================
-- 6. RLS ПОЛИТИКИ ДЛЯ MESSAGES
-- ============================================

-- Включаем Row Level Security для таблицы messages
ALTER TABLE public.messages ENABLE ROW LEVEL SECURITY;

-- Политика: Пользователь может читать сообщения, где он отправитель или получатель
CREATE POLICY "Users can view their own messages"
ON public.messages
FOR SELECT
TO authenticated
USING (
    auth.uid() = sender_id OR auth.uid() = receiver_id
);

-- Политика: Пользователь может отправлять сообщения (быть отправителем)
CREATE POLICY "Users can send messages"
ON public.messages
FOR INSERT
TO authenticated
WITH CHECK (auth.uid() = sender_id);

-- Политика: Пользователь может удалять только свои отправленные сообщения
CREATE POLICY "Users can delete their own messages"
ON public.messages
FOR DELETE
TO authenticated
USING (auth.uid() = sender_id);

-- ============================================
-- 7. STORAGE BUCKET ДЛЯ МЕДИА-ФАЙЛОВ
-- ============================================

-- Создаём публичный Storage бакет для медиа-файлов
-- ВАЖНО: Этот код нужно выполнить в SQL Editor, но bucket может требовать создания через UI

-- Вставка бакета напрямую (если не существует)
INSERT INTO storage.buckets (id, name, public)
VALUES ('chat-media', 'chat-media', true)
ON CONFLICT (id) DO NOTHING;

-- ============================================
-- 8. STORAGE ПОЛИТИКИ ДЛЯ ЗАГРУЗКИ ФАЙЛОВ
-- ============================================

-- Политика: Любой авторизованный пользователь может загружать файлы
CREATE POLICY "Authenticated users can upload media"
ON storage.objects
FOR INSERT
TO authenticated
WITH CHECK (
    bucket_id = 'chat-media' AND
    (storage.foldername(name))[1] IN ('messages', 'avatars', 'banners') AND
    auth.uid()::text = (storage.foldername(name))[2]
);

-- Политика: Любой может просматривать файлы (публичный доступ)
CREATE POLICY "Public read access for media"
ON storage.objects
FOR SELECT
TO public
USING (bucket_id = 'chat-media');

-- Политика: Пользователь может удалять только свои файлы
CREATE POLICY "Users can delete their own media"
ON storage.objects
FOR DELETE
TO authenticated
USING (
    bucket_id = 'chat-media' AND
    auth.uid()::text = (storage.foldername(name))[2]
);

-- Политика: Пользователь может обновлять только свои файлы
CREATE POLICY "Users can update their own media"
ON storage.objects
FOR UPDATE
TO authenticated
USING (
    bucket_id = 'chat-media' AND
    auth.uid()::text = (storage.foldername(name))[2]
)
WITH CHECK (
    bucket_id = 'chat-media' AND
    auth.uid()::text = (storage.foldername(name))[2]
);

-- ============================================
-- 9. ВКЛЮЧАЕМ REALTIME ДЛЯ СООБЩЕНИЙ
-- ============================================

-- Включаем Realtime для таблицы messages
-- (Это можно сделать через UI: Database -> Replication -> messages -> Enable)

ALTER PUBLICATION supabase_realtime ADD TABLE public.messages;

-- ============================================
-- 10. ДОПОЛНИТЕЛЬНЫЕ ФУНКЦИИ
-- ============================================

-- Функция для поиска пользователей по username (с учётом регистра)
CREATE OR REPLACE FUNCTION public.search_users(search_query TEXT)
RETURNS SETOF public.profiles AS $$
BEGIN
    RETURN QUERY
    SELECT *
    FROM public.profiles
    WHERE username ILIKE '%' || search_query || '%'
    AND id != auth.uid()
    ORDER BY created_at DESC
    LIMIT 20;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================
-- ГОТОВО!
-- ============================================

-- После выполнения этого скрипта:
-- 1. Перейдите в Storage на панели Supabase
-- 2. Убедитесь, что бакет 'chat-media' создан и публичный
-- 3. Проверьте, что Realtime включён для таблицы messages:
--    Database -> Replication -> messages -> Enable
-- 4. Скопируйте SUPABASE_URL и SUPABASE_ANON_KEY в index.html
-- 5. Откройте index.html в браузере и наслаждайтесь!

-- Для проверки созданных таблиц:
-- SELECT * FROM public.profiles;
-- SELECT * FROM public.messages;

-- Для проверки политик:
-- SELECT * FROM pg_policies WHERE schemaname = 'public';
