'use strict';
// Loaded before app.js; consumed by its existing field builder and state view.
window.WeaponWorkshopExtras = {
  fields: [
    ['damage', 'Native damage', 'ballistics', 0.1, '×'],
    ['magazineCapacity', 'Magazine capacity', 'ballistics', 0.25, '×'],
    ['projectilesPerShot', 'Projectiles per shot', 'ballistics', 0.25, '×'],
    ['aimSpeed', 'Aim speed', 'ballistics', 0.25, '×'],
    ['chargeSpeed', 'Charge speed', 'ballistics', 0.25, '×'],
    ['smartProjectileSpeed', 'Smart projectile speed', 'ballistics', 0.25, '×']
  ],
  statRows(stats) {
    const value = key => Number.isFinite(stats[key]) ? stats[key].toFixed(3) : '—';
    const optional = key => Number.isFinite(stats[key]) && stats[key] > 0 ? value(key) : 'Not available';
    return [
      ['Physical damage', value('physicalDamage')],
      ['Magazine capacity', value('magazineCapacity')],
      ['Projectiles / shot', value('projectilesPerShot')],
      ['Aim in / out', value('aimInTime') + ' / ' + value('aimOutTime')],
      ['Charge duration', optional('chargeTime')],
      ['Smart projectile speed', optional('smartProjectileVelocity')]
    ];
  }
};
