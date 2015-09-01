import Foundation
import ReactiveCocoa

class ListingsViewModel: NSObject {

    var auctionID = AppSetup.sharedState.auctionID
    var syncInterval = SyncInterval
    var pageSize = 10
    var schedule = { (signal: RACSignal, scheduler: RACScheduler) -> RACSignal in
        return signal.deliverOn(scheduler)
    }
    var logSync = { (date: AnyObject!) -> () in
        #if (arch(i386) || arch(x86_64)) && os(iOS)
            logger.log("Syncing on \(date)")
        #endif
    }

    dynamic var saleArtworks = Array<SaleArtwork>()
    dynamic var sortedSaleArtworks = Array<SaleArtwork>()


    func listingsRequestSignalForPage(auctionID: String, page: Int) -> RACSignal {
        return XAppRequest(.AuctionListings(id: auctionID, page: page, pageSize: self.pageSize)).filterSuccessfulStatusCodes().mapJSON()
    }

    // Repeatedly calls itself with page+1 until the count of the returned array is < pageSize.
    func retrieveAllListingsRequestSignal(auctionID: String, page: Int) -> RACSignal {
        return RACSignal.createSignal { [weak self] (subscriber) -> RACDisposable! in
            self?.listingsRequestSignalForPage(auctionID, page: page).subscribeNext{ (object) -> () in
                if let array = object as? Array<AnyObject> {

                    var nextPageSignal = RACSignal.empty()

                    if array.count >= (self?.pageSize ?? 0) {
                        // Infer we have more results to retrieve
                        nextPageSignal = self?.retrieveAllListingsRequestSignal(auctionID, page: page+1) ?? RACSignal.empty()
                    }

                    RACSignal.`return`(object).concat(nextPageSignal).subscribe(subscriber)
                }
            }

            return nil
        }
    }

    // Fetches all pages of the auction
    func allListingsRequestSignal(auctionID: String) -> RACSignal {
        return schedule(schedule(retrieveAllListingsRequestSignal(auctionID, page: 1), RACScheduler(priority: RACSchedulerPriorityDefault)).collect().map({ (object) -> AnyObject! in
            // object is an array of arrays (thanks to collect()). We need to flatten it.

            let array = object as? Array<Array<AnyObject>>
            return (array ?? []).reduce(Array<AnyObject>(), combine: +)
        }).mapToObjectArray(SaleArtwork.self).`catch`({ (error) -> RACSignal! in

            logger.log("Sale Artworks: Error handling thing: \(error.artsyServerError())")

            return RACSignal.empty()
        }), RACScheduler.mainThreadScheduler())
    }

    func recurringListingsRequestSignal(auctionID: String) -> RACSignal {
        let recurringSignal = RACSignal.interval(syncInterval, onScheduler: RACScheduler.mainThreadScheduler()).startWith(NSDate()).takeUntil(rac_willDeallocSignal())

        return recurringSignal.doNext(logSync).map { [weak self] _ -> AnyObject! in
            return self?.allListingsRequestSignal(auctionID) ?? RACSignal.empty()
            }.switchToLatest().map { [weak self] (newSaleArtworks) -> AnyObject! in
                if self == nil {
                    return [] // Now safe to use self!
                }
                let currentSaleArtworks = self!.saleArtworks

                func update(currentSaleArtworks: [SaleArtwork], newSaleArtworks: [SaleArtwork]) -> Bool {
                    assert(currentSaleArtworks.count == newSaleArtworks.count, "Arrays' counts must be equal.")
                    // Updating the currentSaleArtworks is easy. First we sort both according to the same criteria
                    // Because we assume that their length is the same, we just do a linear scane through and
                    // copy values from the new to the old.

                    let sortedCurentSaleArtworks = currentSaleArtworks.sort(sortById)
                    let sortedNewSaleArtworks = newSaleArtworks.sort(sortById)

                    let saleArtworksCount = sortedCurentSaleArtworks.count
                    for var i = 0; i < saleArtworksCount; i++ {
                        if currentSaleArtworks[i].id == newSaleArtworks[i].id {
                            currentSaleArtworks[i].updateWithValues(sortedNewSaleArtworks[i])
                        } else {
                            // Failure: the list was the same size but had different artworks
                            return false
                        }
                    }

                    return true
                }

                // So we want to do here is pretty simple – if the existing and new arrays are of the same length,
                // then update the individual values in the current array and return the existing value.
                // If the array's length has changed, then we pass through the new array
                if let newSaleArtworks = newSaleArtworks as? Array<SaleArtwork> {
                    if newSaleArtworks.count == currentSaleArtworks.count {
                        if update(currentSaleArtworks, newSaleArtworks: newSaleArtworks) {
                            return currentSaleArtworks
                        }
                    }
                }

                return newSaleArtworks
        }
    }

    // Adapted from https://github.com/FUKUZAWA-Tadashi/FHCCommander/blob/67c67757ee418a106e0ce0c0820459299b3d77bb/fhcc/Convenience.swift#L33-L44
    func getSSID() -> String? {
        let interfaces: CFArray! = CNCopySupportedInterfaces()
        if interfaces == nil { return nil }

        let if0: UnsafePointer<Void>? = CFArrayGetValueAtIndex(interfaces, 0)
        if if0 == nil { return nil }

        let interfaceName: CFStringRef = unsafeBitCast(if0!, CFStringRef.self)
        let dictionary = CNCopyCurrentNetworkInfo(interfaceName) as NSDictionary?
        if dictionary == nil { return nil }

        return dictionary?[kCNNetworkInfoKeySSID as String] as? String
    }

    func detectDevelopment() -> Bool {
        var developmentEnvironment = false
        #if (arch(i386) || arch(x86_64)) && os(iOS)
            developmentEnvironment = true
            #else
            if let ssid = getSSID() {
                let developmentSSIDs = ["Artsy", "Artsy2"] as NSArray
                developmentEnvironment = developmentSSIDs.containsObject(ssid)
            }
        #endif
        return developmentEnvironment
    }

    // MARK: Instance methods

    func saleArtworkAtIndexPath(indexPath: NSIndexPath) -> SaleArtwork {
        return sortedSaleArtworks[indexPath.item];
    }

    // MARK: - Switch Values

    enum SwitchValues: Int {
        case Grid = 0
        case LeastBids
        case MostBids
        case HighestCurrentBid
        case LowestCurrentBid
        case Alphabetical

        var name: String {
            switch self {
            case .Grid:
                return "Grid"
            case .LeastBids:
                return "Least Bids"
            case .MostBids:
                return "Most Bids"
            case .HighestCurrentBid:
                return "Highest Bid"
            case .LowestCurrentBid:
                return "Lowest Bid"
            case .Alphabetical:
                return "A–Z"
            }
        }

        func sortSaleArtworks(saleArtworks: [SaleArtwork]) -> [SaleArtwork] {
            switch self {
            case Grid:
                return saleArtworks
            case LeastBids:
                return saleArtworks.sort(leastBidsSort)
            case MostBids:
                return saleArtworks.sort(mostBidsSort)
            case HighestCurrentBid:
                return saleArtworks.sort(highestCurrentBidSort)
            case LowestCurrentBid:
                return saleArtworks.sort(lowestCurrentBidSort)
            case Alphabetical:
                return saleArtworks.sort(alphabeticalSort)
            }
        }
        
        static func allSwitchValues() -> [SwitchValues] {
            return [Grid, LeastBids, MostBids, HighestCurrentBid, LowestCurrentBid, Alphabetical]
        }
    }
}

// MARK: - Sorting Functions

func leastBidsSort(lhs: SaleArtwork, _ rhs: SaleArtwork) -> Bool {
    return (lhs.bidCount ?? 0) < (rhs.bidCount ?? 0)
}

func mostBidsSort(lhs: SaleArtwork, _ rhs: SaleArtwork) -> Bool {
    return !leastBidsSort(lhs, rhs)
}

func lowestCurrentBidSort(lhs: SaleArtwork, _ rhs: SaleArtwork) -> Bool {
    return (lhs.highestBidCents ?? 0) < (rhs.highestBidCents ?? 0)
}

func highestCurrentBidSort(lhs: SaleArtwork, _ rhs: SaleArtwork) -> Bool {
    return !lowestCurrentBidSort(lhs, rhs)
}

func alphabeticalSort(lhs: SaleArtwork, _ rhs: SaleArtwork) -> Bool {
    return lhs.artwork.sortableArtistID().caseInsensitiveCompare(rhs.artwork.sortableArtistID()) == .OrderedAscending
}

func sortById(lhs: SaleArtwork, _ rhs: SaleArtwork) -> Bool {
    return lhs.id.caseInsensitiveCompare(rhs.id) == .OrderedAscending
}