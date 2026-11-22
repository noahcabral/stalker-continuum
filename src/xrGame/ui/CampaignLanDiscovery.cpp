#include "StdAfx.h"
#include "CampaignLanDiscovery.h"

#ifdef XR_PLATFORM_WINDOWS
#include <winsock2.h>
#include <ws2tcpip.h>
#include <iphlpapi.h>
#include <DPlay/dplay8.h>
#include <wrl/client.h>
#include "xrNetServer/NET_Common.h"
#include "xrNetServer/NET_GameGuid.h"
#include <mutex>

#pragma comment(lib, "iphlpapi.lib")
#pragma comment(lib, "ws2_32.lib")
#pragma comment(lib, "dxguid.lib")

namespace
{
using Microsoft::WRL::ComPtr;
// Keep this in sync with the campaign host command in ui_main_menu.script.
constexpr DWORD CampaignLanPort = 5445;

struct LanSubnet
{
    ULONG mask;
    ULONG network;
};

std::vector<LanSubnet> PhysicalLanSubnets()
{
    std::vector<LanSubnet> subnets;
    ULONG capacity = 16384;
    std::vector<unsigned char> storage(capacity);
    const ULONG flags = GAA_FLAG_SKIP_ANYCAST | GAA_FLAG_SKIP_MULTICAST | GAA_FLAG_SKIP_DNS_SERVER;
    auto* adapters = reinterpret_cast<IP_ADAPTER_ADDRESSES*>(storage.data());
    ULONG result = GetAdaptersAddresses(AF_INET, flags, nullptr, adapters, &capacity);
    if (result == ERROR_BUFFER_OVERFLOW)
    {
        storage.resize(capacity);
        adapters = reinterpret_cast<IP_ADAPTER_ADDRESSES*>(storage.data());
        result = GetAdaptersAddresses(AF_INET, flags, nullptr, adapters, &capacity);
    }
    if (result != NO_ERROR)
        return subnets;

    for (auto* adapter = adapters; adapter; adapter = adapter->Next)
    {
        if (adapter->OperStatus != IfOperStatusUp ||
            (adapter->IfType != IF_TYPE_ETHERNET_CSMACD && adapter->IfType != IF_TYPE_IEEE80211))
            continue;
        MIB_IF_ROW2 interfaceInfo = {};
        interfaceInfo.InterfaceLuid = adapter->Luid;
        if (GetIfEntry2(&interfaceInfo) != NO_ERROR ||
            !interfaceInfo.InterfaceAndOperStatusFlags.HardwareInterface)
            continue;
        for (auto* address = adapter->FirstUnicastAddress; address; address = address->Next)
        {
            const unsigned prefix = address->OnLinkPrefixLength;
            if (prefix == 0 || prefix > 30 || address->Address.lpSockaddr->sa_family != AF_INET)
                continue;
            const auto* ipv4 = reinterpret_cast<const sockaddr_in*>(address->Address.lpSockaddr);
            const ULONG mask = ~ULONG(0) << (32 - prefix);
            const ULONG network = ntohl(ipv4->sin_addr.s_addr) & mask;
            if (std::none_of(subnets.begin(), subnets.end(), [mask, network](const LanSubnet& subnet) {
                    return subnet.mask == mask && subnet.network == network;
                }))
                subnets.push_back({mask, network});
        }
    }
    return subnets;
}

struct Scan
{
    const std::vector<LanSubnet>& subnets;
    std::mutex lock;
    std::vector<std::pair<GUID, CampaignLanHost>> hosts;
};

HRESULT WINAPI OnMessage(void* user, DWORD message, void* data)
{
    if (message != DPN_MSGID_ENUM_HOSTS_RESPONSE)
        return S_OK;
    auto& scan = *static_cast<Scan*>(user);
    const auto& response = *static_cast<const DPNMSG_ENUM_HOSTS_RESPONSE*>(data);
    const auto& description = *response.pApplicationDescription;
    if (description.dwApplicationReservedDataSize != sizeof(GameDescriptionData) ||
        !description.pvApplicationReservedData || (description.dwFlags & DPNSESSION_REQUIREPASSWORD))
        return S_OK;

    wchar_t hostname[INET_ADDRSTRLEN] = {};
    DWORD length = sizeof(hostname);
    DWORD type = 0;
    DWORD port = 0;
    DWORD portLength = sizeof(port);
    if (FAILED(response.pAddressSender->GetComponentByName(DPNA_KEY_HOSTNAME, hostname, &length, &type)) ||
        type != DPNA_DATATYPE_STRING ||
        FAILED(response.pAddressSender->GetComponentByName(DPNA_KEY_PORT, &port, &portLength, &type)) ||
        type != DPNA_DATATYPE_DWORD || port != CampaignLanPort)
        return S_OK;

    IN_ADDR address = {};
    if (InetPtonW(AF_INET, hostname, &address) != 1)
        return S_OK;
    const ULONG hostAddress = ntohl(address.s_addr);
    if (std::none_of(scan.subnets.begin(), scan.subnets.end(), [hostAddress](const LanSubnet& subnet) {
            return (hostAddress & subnet.mask) == subnet.network &&
                hostAddress != subnet.network && hostAddress != (subnet.network | ~subnet.mask);
        }))
        return S_OK;

    const auto& game = *static_cast<const GameDescriptionData*>(description.pvApplicationReservedData);
    const auto* mapEnd = std::find(std::begin(game.map_name), std::end(game.map_name), '\0');
    const auto* versionEnd = std::find(std::begin(game.map_version), std::end(game.map_version), '\0');
    if (mapEnd == std::end(game.map_name) || versionEnd == std::end(game.map_version))
        return S_OK;

    char printable[INET_ADDRSTRLEN] = {};
    if (!InetNtopA(AF_INET, &address, printable, sizeof(printable)))
        return S_OK;
    std::lock_guard<std::mutex> lock(scan.lock);
    if (std::none_of(scan.hosts.begin(), scan.hosts.end(), [&description](const auto& host) {
            return IsEqualGUID(host.first, description.guidInstance);
        }))
    {
        // DirectPlay includes the server in the player counters.
        scan.hosts.emplace_back(description.guidInstance, CampaignLanHost{
            printable, std::string(game.map_name, mapEnd), std::string(game.map_version, versionEnd),
            port, description.dwCurrentPlayers ? description.dwCurrentPlayers - 1 : 0,
            description.dwMaxPlayers ? description.dwMaxPlayers - 1 : 0,
            response.dwRoundTripLatencyMS});
    }
    return S_OK;
}

void ScanSubnets(Scan& scan)
{
    ComPtr<IDirectPlay8Client> client;
    ComPtr<IDirectPlay8Address> local;
    if (FAILED(CoCreateInstance(CLSID_DirectPlay8Client, nullptr, CLSCTX_INPROC_SERVER,
            IID_IDirectPlay8Client, reinterpret_cast<void**>(client.GetAddressOf()))) ||
        FAILED(CoCreateInstance(CLSID_DirectPlay8Address, nullptr, CLSCTX_INPROC_SERVER,
            IID_IDirectPlay8Address, reinterpret_cast<void**>(local.GetAddressOf()))) ||
        FAILED(local->SetSP(&CLSID_DP8SP_TCPIP)) ||
        FAILED(client->Initialize(&scan, OnMessage, 0)))
        return;

    DPN_APPLICATION_DESC search = {};
    search.dwSize = sizeof(search);
    search.guidApplication = NET_GUID;
    DWORD port = CampaignLanPort;
    char query[] = "ToConnect"; // Use the same enumeration request as the game client.
    for (const auto& subnet : scan.subnets)
    {
        IN_ADDR broadcast = {};
        broadcast.s_addr = htonl(subnet.network | ~subnet.mask);
        wchar_t address[INET_ADDRSTRLEN] = {};
        if (!InetNtopW(AF_INET, &broadcast, address, std::size(address)))
            continue;
        ComPtr<IDirectPlay8Address> remote;
        if (FAILED(CoCreateInstance(CLSID_DirectPlay8Address, nullptr, CLSCTX_INPROC_SERVER,
                IID_IDirectPlay8Address, reinterpret_cast<void**>(remote.GetAddressOf()))) ||
            FAILED(remote->SetSP(&CLSID_DP8SP_TCPIP)) ||
            FAILED(remote->AddComponent(DPNA_KEY_PORT, &port, sizeof(port), DPNA_DATATYPE_DWORD)) ||
            FAILED(remote->AddComponent(DPNA_KEY_HOSTNAME, address,
                static_cast<DWORD>((wcslen(address) + 1) * sizeof(wchar_t)), DPNA_DATATYPE_STRING)))
            continue;
        client->EnumHosts(&search, remote.Get(), local.Get(), query, sizeof(query),
            3, 300, 450, nullptr, nullptr, DPNENUMHOSTS_SYNC);
    }
    client->Close(0);
}
}
#endif

std::vector<CampaignLanHost> DiscoverCampaignLanHosts()
{
#ifdef XR_PLATFORM_WINDOWS
    const auto subnets = PhysicalLanSubnets();
    if (subnets.empty() || FAILED(CoInitializeEx(nullptr, COINIT_MULTITHREADED)))
        return {};
    Scan scan{subnets};
    ScanSubnets(scan);
    CoUninitialize();
    std::vector<CampaignLanHost> hosts;
    for (auto& host : scan.hosts)
        hosts.push_back(std::move(host.second));
    return hosts;
#else
    return {};
#endif
}
