# Pharmacy Sync Endpoint Documentation

## Endpoint Info
- **URL**: `POST /api/v1/pharmacy/sync`
- **Controller**: [PharmacySyncController](file:///Users/mohamedayman/Herd/ics/alsaftypharmacies-laravel/app/Http/Controllers/RestAPI/v1/PharmacySyncController.php)
- **Job**: [PharmacySyncJob](file:///Users/mohamedayman/Herd/ics/alsaftypharmacies-laravel/app/Jobs/PharmacySyncJob.php)
- **Route File**: [api.php](file:///Users/mohamedayman/Herd/ics/alsaftypharmacies-laravel/routes/rest_api/v1/api.php#L221)

## Authentication
يجب إرسال الـ API Key في الـ Header:
```
X-API-KEY: eyJhbGciOiJIUzI1NiJ9.test_payload.d8K2mN5pQ7xR4vT9yW1z
```

## Request Structure

### Headers
```http
Content-Type: application/json
X-API-KEY: eyJhbGciOiJIUzI1NiJ9.test_payload.d8K2mN5pQ7xR4vT9yW1z
```

### Body (JSON)
```json
{
  "branches": [
    {
      "branch_code": "BR001",
      "branch_name": "صيدلية الفرع الأول",
      "branch_address": "العنوان التفصيلي للفرع",
      "branch_tel": "0212345678",
      "branch_mobile": "01012345678",
      "active": "Y",
      "products": [
        {
          "code": "PRD001",
          "name_ar": "اسم المنتج بالعربية",
          "name_en": "Product Name English",
          "price": 100.50,
          "quantity": 50,
          "international_barcode": "1234567890123",
          "image": "https://example.com/image.jpg"
        }
      ]
    }
  ]
}
```

## Validation Rules

### Top-level
| Field | Rules |
|-------|-------|
| branches | `required\|array` |

### Branch Object (`branches.*`)
| Field | Rules |
|-------|-------|
| branch_code | `required\|string` |
| branch_name | `required\|string` |
| branch_address | `nullable\|string` |
| branch_tel | `nullable\|string` |
| branch_mobile | `nullable\|string` |
| active | `required\|string\|in:Y,N` |
| products | `required\|array` |

### Product Object (`branches.*.products.*`)
| Field | Rules |
|-------|-------|
| code | `required\|string` |
| name_ar | `required_without:name_en\|string` |
| name_en | `required_without:name_ar\|string` |
| price | `required\|numeric` |
| quantity | `required\|numeric` |
| international_barcode | `nullable\|string` |
| image | `nullable\|string` |

## Response Examples

### Success (200 OK)
```json
{
  "status": "success",
  "message": "تم إرسال طلب المزامنة إلى الـ queue بنجاح",
  "branches_count": 1,
  "total_products_count": 1
}
```

### Unauthorized (401)
```json
{
  "status": "error",
  "message": "غير مصرح لك بالوصول (API Key غير صحيح)"
}
```

### Validation Error (422)
```json
{
  "status": "error",
  "message": "بيانات الطلب غير مكتملة أو غير صحيحة",
  "errors": {
    "branches.0.branch_code": [
      "The branches.0.branch_code field is required."
    ]
  }
}
```

## Notes
1. الـ endpoint يقوم بتنفيذ المزامنة في الخلفية باستخدام Queue Job
2. إذا كانت الكمية (`quantity`) للمنتج الجديد ≤ 0، فلن يتم إنشاؤه
3. يتم إنشاء أو تحديث Seller و Shop لكل فرع
4. يتم مزامنة المنتجات لكل فرع بشكل منفصل (مرتبط بـ seller_id)
