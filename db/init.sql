-- Схема каталога видеоконтента. Выполняется один раз при первом запуске контейнера db.

CREATE TABLE categories (
    id   SERIAL PRIMARY KEY,
    slug TEXT NOT NULL UNIQUE,
    name TEXT NOT NULL
);

INSERT INTO categories (slug, name) VALUES
    ('news',          'Новости'),
    ('politics',      'Политика'),
    ('economy',       'Экономика'),
    ('sport',         'Спорт'),
    ('tech',          'Технологии'),
    ('entertainment', 'Развлечения'),
    ('music',         'Музыка');

CREATE TABLE videos (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    title        TEXT NOT NULL,
    description  TEXT NOT NULL DEFAULT '',
    category_id  INTEGER NOT NULL REFERENCES categories (id),
    status       TEXT NOT NULL DEFAULT 'uploaded'
                 CHECK (status IN ('uploaded', 'processing', 'ready', 'failed')),
    error        TEXT,
    raw_key      TEXT NOT NULL,
    hls_path     TEXT,
    thumb_path   TEXT,
    duration_sec NUMERIC(10, 2),
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX videos_category_created_idx ON videos (category_id, created_at DESC);
CREATE INDEX videos_status_idx ON videos (status);
