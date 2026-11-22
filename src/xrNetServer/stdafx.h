#pragma once

#include "Common/Common.hpp"
#include "xrCore/xrCore.h"
#include "xrCore/_std_extensions.h"

#if defined(XR_PLATFORM_WINDOWS)
#pragma warning(push)
#pragma warning(disable : 4995)
#include <DPlay/dplay8.h>
#pragma warning(pop)
#endif

#include "NET_Shared.h"

#ifdef XR_PLATFORM_WINDOWS
#include "NET_GameGuid.h"

// {8D3F9E5E-A3BD-475b-9E49-B0E77139143C}
static constexpr GUID CLSID_NETWORKSIMULATOR_DP8SP_TCPIP =
{
    0x8d3f9e5e, 0xa3bd, 0x475b, { 0x9e, 0x49, 0xb0, 0xe7, 0x71, 0x39, 0x14, 0x3c }
};
#endif // XR_PLATFORM_WINDOWS
