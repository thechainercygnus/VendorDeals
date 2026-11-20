# Vendor Deals

Vendor Deals finds World of Warcraft: Forever auction listings whose buyout
is lower than the vendor payout for the full stack. It shows the quantity,
buyout, vendor payout, and profit, sorted by highest profit first.

## Install

Download `VendorDeals.zip` from [GitHub Releases](https://github.com/thechainercygnus/VendorDeals/releases)
and extract the `VendorDeals` folder into the client's `Interface\AddOns`
directory. The installed folder should contain `VendorDeals.toc` and
`VendorDeals.lua` directly. Restart WoW and enable **Vendor Deals** in the
character selection AddOns menu.

From the shared AddOns development folder, you can also run
`.\Install-DevelopmentAddOn.ps1 -Name VendorDeals` to install the working copy.

## Use

Open an Auction House and click **Vendor Deals** in the bottom-right corner.
Click the coin icon on the minimap or type `/vendordeals` anywhere to review
saved resale prices and recorded offers. Drag the window by its title or drag
the icon around the minimap. Both positions are saved per character.
Hover over a result to inspect the item. Buy listings through the normal
Auction House controls.

- **With Auctionator:** Run a full scan in replicate mode from Auctionator.
  Vendor Deals reads the completed scan and shares Auctionator's cooldown.
  In the Forever build of Auctionator, enable **Use alternate slower scan
  mode by default** under **Advanced** to select replicate mode.
- **Without Auctionator:** Click **Scan** in Vendor Deals to request its own
  snapshot.

## Vendor resale

Visit a trade supplier to learn prices for supported cooking, tailoring,
blacksmithing, and alchemy supplies. These include spices, thread, dyes, flux,
and vials. Vendor Deals remembers your character's most recently seen cash
price and bundle size for each eligible unlimited-stock item.

Open **Recorded Offers** in the Auction House panel to review the items you
have found, even before scanning. Hover over an offer to see the vendor,
location, and age of the vendor price. **Vendor Resale** combines those
offers with asking prices from the latest completed scan. A new merchant
offer can appear immediately if that scan contained the item.

The view uses the lowest competing asking price and shows estimated profit per
vendor bundle after a 5% cut rounded up to copper. Hover over a row for the
vendor's name and location, the bundle math, and the 12-hour commodity deposit
when the Auction House provides it. Check the Sell tab for other deposits.
Asking prices can change and do not indicate how often a listing sells.

Vendor Resale saves auction prices across reloads and shows their age in the
header. Run a scan after upgrading to populate the saved prices. Below Vendor
keeps its last results until you reload or log out. Check the age of cached
prices before acting on them.
In standalone mode, the Scan button counts down from the last full snapshot
Vendor Deals observed, including across UI reloads.

## Releases

Update the version in `VendorDeals/VendorDeals.toc` before pushing the matching
`vMAJOR.MINOR.PATCH` tag. The release workflow checks the version, packages the
inner addon folder, and publishes `VendorDeals.zip` to GitHub Releases.
