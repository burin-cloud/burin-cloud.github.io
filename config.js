/* BURIN settings for the central cloud site (task 1.4, used when that site goes up in task 1.5).
   Copy this file as config.js next to index.html of the central cloud site and put the two values of the central
   Supabase project (Project Settings, API Keys) between the quotes. Only the Publishable key (sb_publishable_...) goes
   here: never the Secret key, the service_role key or the database password.
   There is no "previous" on purpose: the central cloud is a new project at a new address, nothing is moved into it from
   an older project, and with no "previous" the sign-in is kept under the name 'burin-auth' as on any first project.
   A person who wants their own Supabase sets it in the app (menu, tab "บัญชี ซิงก์ และ AI", the advanced heading). */
window.BURIN_CONFIG = {
  supabaseUrl: 'https://zimxhnrxboclnjexftzv.supabase.co',
  supabaseKey: 'sb_publishable_p9nIZS6esGhD6EtG2FAP6Q_e5ExX00d',
  turnstileKey: ''
};
