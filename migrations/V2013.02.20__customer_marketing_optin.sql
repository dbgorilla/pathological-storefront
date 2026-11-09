-- Cross River Trading Co. -- marketing consent
-- author: R. Vance (contractor)
-- postgres: 9.1
--
-- The mailing list needs to know who agreed to be on it. The import from the
-- old Access file used Y and N, so the column takes Y and N.

-- DEFECT boolean-as-text-marketing-optin
-- A boolean stored as varchar. The 2013 import wrote 'Y' and 'N', the 2016 web
-- form started writing 'yes' and 'no', and rows that predate either are null.
-- Four spellings for two states, and no constraint to stop a fifth.
ALTER TABLE storefront.customers
    ADD COLUMN marketing_optin varchar(255);

COMMENT ON COLUMN storefront.customers.marketing_optin IS
    'Y or N from the 2013 Access import. Later code writes yes or no.';
