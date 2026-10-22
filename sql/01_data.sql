-- 01_data.sql
-- Copies the read-only sample data (samples.bakehouse) into our own schema.
-- Why copy: `samples` is shared and read-only; we need our own tables to
-- enable Change Data Feed (Vector Search) and to grant access to the agent.
-- PII is dropped on purpose: card numbers, emails, phones, names, addresses.

CREATE SCHEMA IF NOT EXISTS dbw_returns_agent.bakehouse_agent
COMMENT 'Bakehouse franchise analyst agent PoC';

CREATE OR REPLACE TABLE dbw_returns_agent.bakehouse_agent.franchises AS
SELECT franchiseID, name, city, district, country, size, supplierID
FROM samples.bakehouse.sales_franchises;

CREATE OR REPLACE TABLE dbw_returns_agent.bakehouse_agent.suppliers AS
SELECT supplierID, name, ingredient, continent, city, size, approved
FROM samples.bakehouse.sales_suppliers;

-- cardNumber is intentionally NOT copied (payment data).
CREATE OR REPLACE TABLE dbw_returns_agent.bakehouse_agent.transactions AS
SELECT transactionID, customerID, franchiseID, dateTime, product,
       quantity, unitPrice, totalPrice, paymentMethod
FROM samples.bakehouse.sales_transactions;

-- Reviews get a string primary key (required by Vector Search) and
-- Change Data Feed (required for a Delta Sync index).
CREATE OR REPLACE TABLE dbw_returns_agent.bakehouse_agent.reviews
TBLPROPERTIES (delta.enableChangeDataFeed = true) AS
SELECT CAST(new_id AS STRING) AS review_id, franchiseID, review_date, review
FROM samples.bakehouse.media_customer_reviews;
