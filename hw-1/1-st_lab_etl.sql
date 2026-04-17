-- TASK 1: Create DWH tables and Staging table

DROP TABLE IF EXISTS Fact_Visit;
DROP TABLE IF EXISTS Dim_Member;
DROP TABLE IF EXISTS Dim_Gym;
DROP TABLE IF EXISTS Dim_Date;
DROP TABLE IF EXISTS Staging_Gym_visit;
DROP TYPE  IF EXISTS day_part_enum;

CREATE TABLE Dim_Member (
    member_id     SERIAL PRIMARY KEY,
    personal_code TEXT NOT NULL UNIQUE,
    last_name     TEXT NOT NULL,
    first_name    TEXT NOT NULL
);

CREATE TABLE Dim_Gym (
    gym_id   SERIAL PRIMARY KEY,
    gym_code TEXT NOT NULL UNIQUE
);

CREATE TABLE Dim_Date (
    date_key              DATE PRIMARY KEY,
    day_number_of_month   INT  NOT NULL,
    month_number_of_year  INT  NOT NULL,
    year_number           INT  NOT NULL,
    day_name              TEXT NOT NULL,
    month_name            TEXT NOT NULL
);

CREATE TYPE day_part_enum AS ENUM ('Morning', 'Day', 'Evening');

CREATE TABLE Fact_Visit (
    visit_id       SERIAL PRIMARY KEY,
    gym_id         INT NOT NULL REFERENCES Dim_Gym(gym_id),
    member_id      INT NOT NULL REFERENCES Dim_Member(member_id),
    visit_date_key DATE NOT NULL REFERENCES Dim_Date(date_key),
    visit_duration INT NOT NULL,
    day_part       day_part_enum NOT NULL
);

CREATE TABLE Staging_Gym_visit (
    v_id                      SERIAL PRIMARY KEY,
    visit_date                DATE,
    gym_code                  TEXT,
    personal_code             TEXT,
    visitor_name              TEXT,
    time_in                   TIME,
    time_out                  TIME,
    require_manual_processing INT DEFAULT 0
);


-- TASK 1: Populate Dim_Gym and Dim_Member


INSERT INTO Dim_Gym (gym_code) VALUES ('Gym_1'), ('Gym_2');

INSERT INTO Dim_Member (personal_code, last_name, first_name) VALUES
    ('P1', 'L1', 'F1'),
    ('P2', 'L2', 'F2'),
    ('P3', 'L3', 'F3'),
    ('P4', 'L4', 'F4'),
    ('P5', 'L5', 'F5'),
    ('P6', 'L6', 'F6');


-- TASK 1: Add initial data to Staging table (HT1_part1.sql)


INSERT INTO Staging_Gym_visit (visit_date, gym_code, personal_code, visitor_name, time_in, time_out)
VALUES
    ('2025-04-01', 'Gym_1', 'P1', 'L1 F1', '15:00', '13:00'),
    ('2025-04-03', 'Gym_1', 'P1', 'L1 F1', '16:00', '17:00'),
    ('2025-04-03', 'Gym_1', 'P1', 'L1 F1', '16:00', '17:00'),
    ('2025-04-04', 'Gym_1', 'P2', 'L2 F2', '16:20', '18:10'),
    ('2025-04-04', 'Gym_1', 'P3', 'L3 F3', '19:45', NULL),
    ('2025-04-04', 'Gym_1', 'P4', 'L4 F4', '16:00', '15:00'),
    ('2025-04-02', 'Gym_1', 'P3', 'L1 F1', '8:20',  '9:30'),
    ('2025-04-03', 'Gym_2', 'P5', 'F5 L5', '7:20',  NULL),
    ('2025-04-03', 'Gym_2', 'P5', 'F5 L5', NULL,    '8:20'),
    ('2025-04-04', 'Gym_2', 'P6', 'F6 L6', '18:30', NULL),
    ('2025-04-04', 'Gym_2', 'P6', 'F6 L6', NULL,    '19:50'),
    ('2025-04-04', 'Gym_2', 'P5', 'F5 L5', '9:30',  NULL),
    ('2025-04-01', 'Gym_1', 'P1', NULL,     '7:00',  '8:00');


INSERT INTO Staging_Gym_visit (visit_date, gym_code, personal_code, visitor_name, time_in, time_out)
VALUES
    ('2025-04-04', 'Gym_1', 'P3', 'L3 F3', '19:45', '21:15'),
    ('2025-04-04', 'Gym_2', 'P5', 'F5 L5', NULL,    '10:40'),
    ('2025-04-05', 'Gym_1', 'P1', 'L1 F1', '16:00', '17:00');


-- TASK 2: ETL procedure — transfer data from Staging to DWH tables

CREATE OR REPLACE PROCEDURE etl_staging_to_dwh()
LANGUAGE plpgsql
AS $$
DECLARE
    rec             RECORD;
    v_gym_id        INT;
    v_member_id     INT;
    v_last_name     TEXT;
    v_first_name    TEXT;
    v_expected_name TEXT;
    v_time_in       TIME;
    v_time_out      TIME;
    v_duration      INT;
    v_day_part      day_part_enum;
    v_min_row_id    INT;
BEGIN

    -- TASK 2: Merge Gym_2 two-row visits into one row
    UPDATE Staging_Gym_visit s1
    SET    time_out = s2.time_out
    FROM   Staging_Gym_visit s2
    WHERE  s1.gym_code      = 'Gym_2'
      AND  s2.gym_code      = 'Gym_2'
      AND  s1.personal_code = s2.personal_code
      AND  s1.visit_date    = s2.visit_date
      AND  s1.time_in  IS NOT NULL
      AND  s1.time_out IS NULL
      AND  s2.time_in  IS NULL
      AND  s2.time_out IS NOT NULL
      AND  s1.require_manual_processing = 0
      AND  s2.require_manual_processing = 0;

    UPDATE Staging_Gym_visit
    SET    require_manual_processing = 2
    WHERE  gym_code  = 'Gym_2'
      AND  time_in   IS NULL
      AND  time_out  IS NOT NULL
      AND  require_manual_processing = 0;

    -- TASK 2: Handle duplicate data
    UPDATE Staging_Gym_visit s
    SET    require_manual_processing = 2
    WHERE  require_manual_processing = 0
      AND  v_id NOT IN (
               SELECT MIN(v_id)
               FROM   Staging_Gym_visit
               WHERE  require_manual_processing = 0
               GROUP  BY visit_date, gym_code, personal_code,
                         time_in, time_out
           );

    FOR rec IN
        SELECT * FROM Staging_Gym_visit
        WHERE  require_manual_processing = 0
        ORDER  BY v_id
    LOOP

        -- TASK 2: Transfer only completed visits (time_out IS NOT NULL)
        IF rec.time_out IS NULL THEN
            CONTINUE;
        END IF;

        -- TASK 2: Mark rows with time_out <= time_in for manual processing
        IF rec.time_in IS NULL OR rec.time_out <= rec.time_in THEN
            UPDATE Staging_Gym_visit
            SET    require_manual_processing = 1
            WHERE  v_id = rec.v_id;
            CONTINUE;
        END IF;

        SELECT gym_id INTO v_gym_id
        FROM   Dim_Gym
        WHERE  gym_code = rec.gym_code;

        IF NOT FOUND THEN
            UPDATE Staging_Gym_visit
            SET    require_manual_processing = 1
            WHERE  v_id = rec.v_id;
            CONTINUE;
        END IF;

        SELECT member_id, last_name, first_name
        INTO   v_member_id, v_last_name, v_first_name
        FROM   Dim_Member
        WHERE  personal_code = rec.personal_code;

        IF NOT FOUND THEN
            UPDATE Staging_Gym_visit
            SET    require_manual_processing = 1
            WHERE  v_id = rec.v_id;
            CONTINUE;
        END IF;

        -- TASK 2: Verify personal_code matches visitor_name
        IF rec.visitor_name IS NOT NULL THEN
            IF rec.gym_code = 'Gym_1' THEN
                v_expected_name := v_last_name || ' ' || v_first_name;
            ELSE
                v_expected_name := v_first_name || ' ' || v_last_name;
            END IF;

            IF rec.visitor_name <> v_expected_name THEN
                UPDATE Staging_Gym_visit
                SET    require_manual_processing = 1
                WHERE  v_id = rec.v_id;
                CONTINUE;
            END IF;
        END IF;

        -- TASK 2: Calculate visit duration in minutes
        v_duration := EXTRACT(EPOCH FROM (rec.time_out - rec.time_in))::INT / 60;

        -- TASK 2: Calculate day_part from time_in
        IF rec.time_in <= '10:00' THEN
            v_day_part := 'Morning';
        ELSIF rec.time_in <= '17:00' THEN
            v_day_part := 'Day';
        ELSE
            v_day_part := 'Evening';
        END IF;

        -- TASK 2: Populate missing dates in Dim_Date
        INSERT INTO Dim_Date (
            date_key,
            day_number_of_month,
            month_number_of_year,
            year_number,
            day_name,
            month_name
        )
        VALUES (
            rec.visit_date,
            EXTRACT(DAY   FROM rec.visit_date)::INT,
            EXTRACT(MONTH FROM rec.visit_date)::INT,
            EXTRACT(YEAR  FROM rec.visit_date)::INT,
            TO_CHAR(rec.visit_date, 'Day'),
            TO_CHAR(rec.visit_date, 'Month')
        )
        ON CONFLICT (date_key) DO NOTHING;

        INSERT INTO Fact_Visit (gym_id, member_id, visit_date_key, visit_duration, day_part)
        VALUES (v_gym_id, v_member_id, rec.visit_date, v_duration, v_day_part);

        -- TASK 2: Remove processed rows from Staging table
        UPDATE Staging_Gym_visit
        SET    require_manual_processing = 2
        WHERE  v_id = rec.v_id;

    END LOOP;

END;
$$;

-- TASK 2 + 3: Run ETL for part 1 data, then again for part 2 data
CALL etl_staging_to_dwh();
CALL etl_staging_to_dwh();

SELECT
    fv.visit_id,
    dg.gym_code,
    dm.personal_code,
    dm.last_name || ' ' || dm.first_name AS member_name,
    fv.visit_date_key,
    dd.day_name,
    fv.visit_duration AS duration_min,
    fv.day_part
FROM  Fact_Visit  fv
JOIN  Dim_Gym     dg ON dg.gym_id    = fv.gym_id
JOIN  Dim_Member  dm ON dm.member_id = fv.member_id
JOIN  Dim_Date    dd ON dd.date_key  = fv.visit_date_key
ORDER BY fv.visit_id;

SELECT * FROM Staging_Gym_visit WHERE require_manual_processing = 1;
SELECT * FROM Staging_Gym_visit WHERE require_manual_processing = 0;