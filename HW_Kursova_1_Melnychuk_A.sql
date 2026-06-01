--КУРСОВА 1

SELECT *
FROM public.cohort_users_raw
LIMIT 10;


SELECT *
FROM public.cohort_events_raw
LIMIT 10;


/* 
Когортний аналіз користувачів
Запит складається з 4 кроків:
1. Підготовка даних користувачів
2. Підготовка даних подій
3. Об'єднання таблиць та розрахунок когорт
4. Фінальна агрегація
Запит побудований за принципом каскадних CTE, які дозволяють розбити складну логіку 
на зрозумілі кроки, де кожна наступна таблиця використовує результати попередньої.
*/

WITH users_parsed AS (
/* КРОК 1. Підготовка та очищення даних користувачів (users_parsed)
	Очищаємо дату реєстрації (signup_datetime). Спочатку прибираємо зайві пробіли і час за допомогою TRIM та SPLIT_PART, 
    потім замінюємо розділювачі (. або /) на '-' за допомогою REPLACE. Далі використовуємо CASE, 
    щоб перевірити довжину року (4 або 2 цифри) і перетворити рядок у дату за допомогою TO_DATE. Якщо формат не підходить, повертаємо NULL. 
    Це забезпечує, що дата стає коректною датою в базі даних.*/
    SELECT 
        user_id,
        promo_signup_flag,
        -- Використовуємо CASE для обробки різних текстових форматів року (2 або 4 цифри)
        CASE 
            -- Очищення: TRIM для видалення пробілів, SPLIT_PART для відсікання часу, REPLACE для уніфікації розділювачів, щоб привести все до стандарту. 
            WHEN LENGTH(SPLIT_PART(REPLACE(REPLACE(TRIM(SPLIT_PART(signup_datetime, ' ', 1)), '.', '-'), '/', '-'), '-', 3)) = 4 
                THEN TO_DATE(REPLACE(REPLACE(TRIM(SPLIT_PART(signup_datetime, ' ', 1)), '.', '-'), '/', '-'), 'DD-MM-YYYY')
            WHEN LENGTH(SPLIT_PART(REPLACE(REPLACE(TRIM(SPLIT_PART(signup_datetime, ' ', 1)), '.', '-'), '/', '-'), '-', 3)) = 2 
                THEN TO_DATE(REPLACE(REPLACE(TRIM(SPLIT_PART(signup_datetime, ' ', 1)), '.', '-'), '/', '-'), 'DD-MM-YY')
            ELSE NULL 
        END AS signup_ts -- Тимчасовий аліас для очищеної дати реєстрації 
    FROM cohort_users_raw
),
						/* Перевірка кроку 1: Можна розкоментувати для тестування */
						--  SELECT * FROM users_parsed LIMIT 20; 
events_parsed AS (
-- КРОК 2. Підготовка та очищення даних подій (events_parsed)
/*Аналогічно до користувачів, очищаємо дату події (event_datetime). 
Прибираємо пробіли і час, замінюємо розділювачі на '-', перевіряємо довжину року в CASE і перетворюємо в дату за допомогою TO_DATE. 
Це робить дату подій готовою для розрахунків різниці місяців.*/
      SELECT 
        user_id,
        event_type,
        -- Повторюємо логіку очищення для таблиці подій
        CASE 
            WHEN LENGTH(SPLIT_PART(REPLACE(REPLACE(TRIM(SPLIT_PART(event_datetime, ' ', 1)), '.', '-'), '/', '-'), '-', 3)) = 4 
                THEN TO_DATE(REPLACE(REPLACE(TRIM(SPLIT_PART(event_datetime, ' ', 1)), '.', '-'), '/', '-'), 'DD-MM-YYYY')
            WHEN LENGTH(SPLIT_PART(REPLACE(REPLACE(TRIM(SPLIT_PART(event_datetime, ' ', 1)), '.', '-'), '/', '-'), '-', 3)) = 2 
                THEN TO_DATE(REPLACE(REPLACE(TRIM(SPLIT_PART(event_datetime, ' ', 1)), '.', '-'), '/', '-'), 'DD-MM-YY')
            ELSE NULL 
        END AS event_ts -- Тимчасовий аліас для очищеної дати події
    FROM cohort_events_raw
), 
						/* Перевірка кроку 2: Можна розкоментувати для тестування */
						--SELECT * FROM events_parsed LIMIT 20;
user_activity AS (
    /* КРОК 3. Об'єднання користувачів і подій + розрахунок когорт (user_activity)*/
/* Об'єднуємо таблиці за user_id за допомогою JOIN. Перетворюємо дати в формат рік-місяць за допомогою DATE_TRUNC('month'),
  щоб отримати cohort_month (когорта реєстрації) та activity_month (місяць активності). 
  Розраховуємо month_offset як різницю в місяцях між датою події та реєстрацією 
  за допомогою EXTRACT(YEAR) та EXTRACT(MONTH) — це показує стаж користувача. 
  Фільтрація виключає некоректні дані (відсутні дати, NULL типи, тестові події), але зберігає 'registration' для 0-го місяця.*/
    SELECT
        u.user_id,
        u.promo_signup_flag,
        -- Перетворення дат у формат рік-місяць
        DATE_TRUNC('month', u.signup_ts)::DATE AS cohort_month, -- Визначаємо місяць реєстрації
        DATE_TRUNC('month', e.event_ts)::DATE AS activity_month, -- Визначаємо місяць активності
          /* Розрахунок стажу користувача(різниця в місяцях) (month_offset).
           Показує, скільки місяців пройшломіж реєстрацією та подією. */
        ((EXTRACT(YEAR FROM e.event_ts) - EXTRACT(YEAR FROM u.signup_ts)) * 12 +
         (EXTRACT(MONTH FROM e.event_ts) - EXTRACT(MONTH FROM u.signup_ts))) AS month_offset
    FROM users_parsed u
    JOIN events_parsed e ON u.user_id = e.user_id
    WHERE u.signup_ts IS NOT NULL
      AND e.event_ts IS NOT NULL
      AND e.event_type IS NOT NULL
      AND e.event_type <> 'test_event' -- Виключення тестових подій
)
					/* Перевірка кроку 3: Можна розкоментувати для тестування*/
					-- SELECT * FROM user_activity LIMIT 50;
/* КРОК 4. Фінальна агрегація */
/*  Агрегуємо дані. Групуємо за promo_signup_flag, cohort_month та month_offset, 
рахуємо кількість унікальних користувачів (users_total) за допомогою COUNT(DISTINCT user_id).
Нам потрібно знати, скільки унікальних користувачів з певної когорти зробили хоча б одну дію у свій місяць стажу. 
Обмежуємо період активності січень — червень 2025 за допомогою BETWEEN для activity_month. 
Сортуємо результат для зручності перегляду. Це дає готову таблицю для експорту в Google Sheets.*/
SELECT
    promo_signup_flag,
    cohort_month,
    month_offset,
    -- Кількість унікальних користувачів
    COUNT(DISTINCT user_id) AS users_total
FROM user_activity
/* Обмеження періоду активності: січень — червень 2025 через BETWEEN */
WHERE activity_month BETWEEN '2025-01-01' AND '2025-06-01'
GROUP BY 
    promo_signup_flag, 
    cohort_month, 
    month_offset
ORDER BY 
    promo_signup_flag, 
    cohort_month, 
    month_offset;

