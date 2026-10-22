-- 02_tools.sql
-- Unity Catalog SQL functions = the agent's structured-data tools.
-- The agent never receives table access: it can only call these functions,
-- so what it can read is defined (and governed) here.
-- The COMMENT text is what the LLM reads to decide when to call each tool.

CREATE OR REPLACE FUNCTION dbw_returns_agent.bakehouse_agent.find_franchise(
  search_text STRING COMMENT 'Part of a franchise name, city, district or country, e.g. "Tokyo" or "Crumbs"'
)
RETURNS TABLE (franchiseID BIGINT, name STRING, city STRING, district STRING, country STRING, size STRING)
COMMENT 'Finds franchises by name, city, district or country. Use it first to resolve a franchise name into its franchiseID.'
RETURN
  SELECT franchiseID, name, city, district, country, size
  FROM dbw_returns_agent.bakehouse_agent.franchises
  WHERE lower(name) LIKE concat('%', lower(search_text), '%')
     OR lower(city) LIKE concat('%', lower(search_text), '%')
     OR lower(district) LIKE concat('%', lower(search_text), '%')
     OR lower(country) LIKE concat('%', lower(search_text), '%');

CREATE OR REPLACE FUNCTION dbw_returns_agent.bakehouse_agent.franchise_sales(
  franchise_id BIGINT COMMENT 'franchiseID obtained from find_franchise',
  start_date DATE COMMENT 'First day, inclusive. Data exists only from 2024-05-01 to 2024-05-17',
  end_date DATE COMMENT 'Last day, inclusive'
)
RETURNS TABLE (product STRING, units BIGINT, revenue BIGINT)
COMMENT 'Units sold and revenue (USD) per product for one franchise in a date range. Data covers 2024-05-01 to 2024-05-17 only.'
RETURN
  SELECT product, SUM(quantity) AS units, SUM(totalPrice) AS revenue
  FROM dbw_returns_agent.bakehouse_agent.transactions
  WHERE franchiseID = franchise_id
    AND CAST(dateTime AS DATE) BETWEEN start_date AND end_date
  GROUP BY product
  ORDER BY revenue DESC;

CREATE OR REPLACE FUNCTION dbw_returns_agent.bakehouse_agent.top_franchises(
  top_n INT COMMENT 'How many franchises to return, e.g. 5'
)
RETURNS TABLE (franchiseID BIGINT, name STRING, city STRING, country STRING, revenue BIGINT, transactions BIGINT)
COMMENT 'Ranking of franchises by total revenue (USD) over the whole available period (2024-05-01 to 2024-05-17).'
RETURN
  -- LIMIT cannot take a function parameter in SQL UDFs, so we rank and filter instead.
  SELECT franchiseID, name, city, country, revenue, transactions FROM (
    SELECT f.franchiseID, f.name, f.city, f.country,
           SUM(t.totalPrice) AS revenue, COUNT(*) AS transactions,
           row_number() OVER (ORDER BY SUM(t.totalPrice) DESC) AS rnk
    FROM dbw_returns_agent.bakehouse_agent.transactions t
    JOIN dbw_returns_agent.bakehouse_agent.franchises f USING (franchiseID)
    GROUP BY f.franchiseID, f.name, f.city, f.country
  ) WHERE rnk <= top_n
  ORDER BY revenue DESC;

CREATE OR REPLACE FUNCTION dbw_returns_agent.bakehouse_agent.franchise_supplier(
  franchise_id BIGINT COMMENT 'franchiseID obtained from find_franchise'
)
RETURNS TABLE (supplier STRING, ingredient STRING, continent STRING, approved STRING)
COMMENT 'Supplier of a franchise: name, main ingredient, continent and whether it is approved (Y/N).'
RETURN
  SELECT s.name AS supplier, s.ingredient, s.continent, s.approved
  FROM dbw_returns_agent.bakehouse_agent.franchises f
  JOIN dbw_returns_agent.bakehouse_agent.suppliers s USING (supplierID)
  WHERE f.franchiseID = franchise_id;
