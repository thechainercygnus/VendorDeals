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

Open an Auction House and click **Vendor Deals** in the bottom-right corner,
or type `/vendordeals`. Hover over a result to inspect the item. Buy listings
through the normal Auction House controls.

- **With Auctionator:** Run a full scan in replicate mode from Auctionator.
  Vendor Deals reads the completed scan and shares Auctionator's cooldown.
  In the Forever build of Auctionator, enable **Use alternate slower scan
  mode by default** under **Advanced** to select replicate mode.
- **Without Auctionator:** Click **Scan** in Vendor Deals to request its own
  snapshot.

## Vendor resale

Visit a cooking supply vendor that sells Mild Spices, Hot Spices, or Soothing
Spices. Vendor Deals remembers the character's most recently seen cash price
and bundle size for each unlimited-stock item. Then open the Auction House,
scan as above, and choose **Vendor Resale**.

The view uses the lowest competing asking price and shows estimated profit per
vendor bundle after a 5% cut rounded up to copper. Hover over a row for the
vendor's name and location, the bundle math, and the 12-hour commodity deposit
when the Auction House provides it. Check the Sell tab for other deposits.
Asking prices can change and do not indicate how often a listing sells.

Both views keep the last completed scan when you close and reopen the Auction
House during the same UI session. Check **Last scan** before acting on a price.
In standalone mode, the Scan button counts down from the last full snapshot
Vendor Deals observed, including across UI reloads.

## Releases

Update the version in `VendorDeals/VendorDeals.toc` before pushing the matching
`vMAJOR.MINOR.PATCH` tag. The release workflow checks the version, packages the
inner addon folder, and publishes `VendorDeals.zip` to GitHub Releases.
